// (c) Kallol Borah, 2020
// Implementation of the Via zero coupon bond.

pragma solidity >=0.5.0 <0.7.0;

import "./erc/ERC20.sol";
import "./oraclize/ViaRate.sol";
import "./oraclize/EthToUSD.sol";
import "./utilities/DayCountConventions.sol";
import "./utilities/SafeMath.sol";
import "./utilities/StringUtils.sol";
import "@openzeppelin/upgrades/contracts/Initializable.sol";
import "@openzeppelin/contracts-ethereum-package/contracts/ownership/Ownable.sol";
import "./Factory.sol";

contract Bond is ERC20, Initializable, Ownable {

    using stringutils for *;

    //via token factory address
    Factory private factory;

    //name of Via token (eg, Via-USD%)
    bytes32 public name;
    bytes32 public symbol;

    struct cash{
        bytes32 name;
        uint256 balance;
    }

    //cash balances held by this issuer against which via bond tokens are issued
    mapping(address => cash[]) private cashbalances;

    //a Via bond has some value, corresponds to a fiat currency
    //has a borrower and lender that have agreed to a zero coupon rate which is the start price of the bond
    //and a tenure in unix timestamps of seconds counted from 1970-01-01. Via bonds are of one year tenure.
    //constructor for creating Via bond
    struct loan{
        address borrower;
        bytes32 currency;
        uint256 faceValue;
        uint256 price;
        uint256 collateralAmount;
        bytes32 collateralCurrency;
        uint256 timeOfIssue;
        uint tenure; 
    }

    mapping(address => loan[]) public loans;

    //for Oraclize
    bytes32 EthXid;
    bytes32 ViaXid;
    bytes32 ViaRateId;
    
    struct conversion{
        bytes32 operation;
        address party;
        uint256 amount;
        bytes32 currency;
        bytes32 EthXid;
        uint256 EthXvalue;
        bytes32 name;
        uint256 ViaXvalue;
        bytes32 ViaRateId;
        uint256 ViaRateValue;
    }

    mapping(bytes32 => conversion) private conversionQ;

    bytes32[] private conversions;

    //events to capture and report to Via oracle
    event ViaBondIssued(bytes32 currency, uint value, uint price, uint tenure);
    event ViaBondRedeemed(bytes32 currency, uint value, uint price, uint tenure);

    //initiliaze proxies
    function initialize(bytes32 _name, address _owner) public {
        Ownable.initialize(_owner);
        factory = Factory(_owner);
        name = _name;
        symbol = _name;
    }    

    //handling pay in of ether for issue of via bond tokens
    function() payable external{
        //ether paid in
        require(msg.value !=0);
        //issue via bond tokens
        issue(msg.value, msg.sender, "ether");
    }

    //overriding this function of ERC20 standard
    function transferFrom(address sender, address receiver, uint256 tokens) public returns (bool){
        //owner should have more tokens than being transferred
        require(tokens <= balances[sender]);
        //sending contract should be allowed by token owner to make this transfer
        require(tokens <= allowed[sender][msg.sender]);
        //check if tokens are being transferred to this bond contract
        if(receiver == address(this)){ 
            //if token name is the same, this transfer has to be redeemed
            if(Bond(address(msg.sender)).name()==name){ 
                if(redeem(tokens, receiver))
                    return true;
                else
                    return false;
            }
            //else request issue of bond tokens generated by this contract
            else{
                //issue only if paid in tokens are cash tokens, since bond tokens can't be paid to issue bond token
                for(uint256 p=0; p<factory.getTokenCount(); p++){
                    address viaAddress = factory.tokens(p);
                    if(factory.getName(viaAddress) == Bond(address(msg.sender)).name() &&
                        factory.getType(viaAddress) != "ViaBond"){
                        issue(tokens, receiver, Bond(address(msg.sender)).name());
                        return true;
                    }
                }
                return false;
            }
        } 
        else { 
            //tokens are being sent to a user account
            balances[sender] = balances[sender].sub(tokens);
            allowed[sender][msg.sender] = allowed[sender][msg.sender].sub(tokens);
            balances[receiver] = balances[receiver].add(tokens);
            emit Transfer(sender, receiver, tokens);
            return true;
        }                
    }

    //requesting issue of Via bonds to borrower for amount of paid in currency as collateral
    function issue(uint256 amount, address borrower, bytes32 currency) private {
        //ensure that brought amount is not zero
        require(amount != 0);
        bool found = false;
        uint256 p=0;
        //adds paid in currency to this contract's cash balance
        for(p=0; p<cashbalances[address(this)].length; p++){
            if(cashbalances[address(this)][p].name == currency){
                cashbalances[address(this)][p].balance += amount;
                found = true;
            }
        }
        if(!found){
            cashbalances[address(this)][p].name = currency;
            cashbalances[address(this)][p].balance = amount;
        }
        //call Via Oracle to fetch data for bond pricing
        if(currency=="ether"){
            EthXid = new EthToUSD().update("Bond", address(this));
            if(name!="Via-USD"){
                ViaXid = new ViaRate().requestPost(abi.encodePacked("Via_USD_to_", name),"ver","Bond", address(this));
            }
        }
        else{
            ViaXid = new ViaRate().requestPost(abi.encodePacked(currency, "_to_", name),"er","Bond", address(this));
            if(currency!="Via-USD"){
                ViaRateId = new ViaRate().requestPost(abi.encodePacked("Via_USD_to_", currency), "ir","Bond",address(this));
            }
            else{
                ViaRateId = new ViaRate().requestPost("USD", "ir","Bond",address(this));
            }
        }
        conversionQ[ViaXid] = conversion("issue", borrower, amount, currency, EthXid, 0, name, 0, ViaRateId, 0);
        conversions.push(ViaXid);

        //find face value of bond in via denomination
        //faceValue = convertToVia(amount, currency);
        //find price of via bonds to transfer after applying exchange rate
        //viaBondPrice = getBondValueToIssue(faceValue, currency, 1);
        
    }

    //requesting redemption of Via bonds and transfer of ether or via cash collateral to borrower 
    //to do : redemption of Via bonds for fiat currency
    function redeem(uint256 amount, address borrower) private returns(bool){
        //ensure that sold amount is not zero
        require(amount != 0);
        //find currency that borrower had deposited earlier
        bool found = false;
        bytes32 currency;

        for(uint256 p=0; p<loans[address(this)].length; p++){
            if(loans[address(this)][p].borrower == borrower){
                currency = loans[address(this)][p].currency;
                found = true;
            }
        }
        if(found){
            //call Via oracle
            if(currency=="ether"){
                EthXid = new EthToUSD().update("Bond", address(this));
                ViaXid = new ViaRate().requestPost(abi.encodePacked(name, "_to_Via_USD"),"ver","Bond", address(this));
            }
            else{
                ViaXid = new ViaRate().requestPost(abi.encodePacked(name, "_to_", currency),"er","Bond", address(this));
            }
            conversionQ[ViaXid] = conversion("redeem", borrower, amount, currency, EthXid, 0, name, 0, 0, 0);
            conversions.push(ViaXid);

            //find redemption amount to transfer 
            //var(redemptionAmount, balanceTenure) = getBondValueToRedeem(amount, currency, borrower);
            //only if the issuer's balance of the deposited currency is more than or equal to amount redeemed
        }
        return found;
    }

    //function called back from Oraclize
    function convert(bytes32 txId, uint256 result, bytes32 rtype) public {
        //check type of result returned
        if(rtype =="ethusd"){
            conversionQ[txId].EthXvalue = result;
        }
        if(rtype == "ir"){
            conversionQ[txId].ViaRateValue = result;
        }
        if(rtype == "er"){
            conversionQ[txId].EthXvalue = result;
        }
        if(rtype == "ver"){
            conversionQ[txId].ViaXvalue = result;
        }
        //check if bond needs to be issued or redeemed
        if(conversionQ[txId].operation=="issue"){
            if(conversionQ[txId].EthXvalue!=0 && conversionQ[txId].ViaXvalue!=0 && conversionQ[txId].ViaRateValue!=0){
                uint256 faceValue = convertToVia(conversionQ[txId].amount, conversionQ[txId].currency,conversionQ[txId].EthXvalue,result);
                uint256 viaBondPrice = getBondValueToIssue(faceValue, conversionQ[txId].currency, 1, conversionQ[txId].EthXvalue, conversionQ[txId].ViaXvalue);
                finallyIssue(viaBondPrice, faceValue, txId);
            }
        }
        else if(conversionQ[txId].operation=="redeem"){
            if(conversionQ[txId].EthXvalue!=0 && conversionQ[txId].ViaXvalue!=0){
                (uint256 redemptionAmount, uint balanceTenure) = getBondValueToRedeem(conversionQ[txId].amount, conversionQ[txId].currency, conversionQ[txId].party,conversionQ[txId].EthXvalue, result);
                finallyRedeem(conversionQ[txId].amount, conversionQ[txId].currency, conversionQ[txId].party, redemptionAmount, balanceTenure);
            }
        }
    }

    function finallyIssue(uint256 viaBondPrice, uint256 faceValue, bytes32 txId) private {
        //add via bonds to this contract's balance first
        balances[address(this)].add(viaBondPrice);
        //transfer amount from issuer/sender to borrower
        transfer(conversionQ[txId].party, viaBondPrice);
        //adjust total supply
        totalSupply_ += viaBondPrice;
        //keep track of issues
        storeIssuedBond(conversionQ[txId].party, name, faceValue, viaBondPrice, conversionQ[txId].amount, conversionQ[txId].currency, now, 1);
        //generate event
        emit ViaBondIssued(name, conversionQ[txId].amount, viaBondPrice, 1);
    }

    function finallyRedeem(uint256 amount, bytes32 currency, address borrower, uint256 redemptionAmount, uint balanceTenure) private{
        for(uint256 p=0; p<cashbalances[address(this)].length; p++){
            //check if currency in which redemption is to be done is available in cash balances
            if(cashbalances[address(this)][p].name == currency){
                //check if currency in which redemption is to be done has sufficient balance
                if(cashbalances[address(this)][p].balance > redemptionAmount){
                    //deduct amount to be transferred from cash balance
                    cashbalances[address(this)][p].balance -= redemptionAmount;
                    //transfer amount from issuer/sender to borrower 
                    transfer(borrower, redemptionAmount);
                    //adjust total supply
                    totalSupply_ =- amount;
                    //generate event
                    emit ViaBondRedeemed(currency, amount, redemptionAmount, balanceTenure);
                }
            }
        }
    }

    //get Via exchange rates from oracle and convert given currency and amount to via cash token
    function convertToVia(uint256 amount, bytes32 currency, uint256 ethusd, uint256 viarate) private returns(uint256){
        if(currency=="ether"){
            //to first convert amount of ether passed to this function to USD
            uint256 amountInUSD = (amount/10^18)*ethusd;
            //to then convert USD to Via-currency if currency of this contract is not USD itself
            if(name!="Via-USD"){
                uint256 inVia = amountInUSD * viarate;
                return inVia;
            }
            else{
                return amountInUSD;
            }
        }
        //if currency paid in another via currency
        else{
            uint256 inVia = viarate;
            return inVia;
        }
    }

    //convert Via-currency (eg, Via-EUR, Via-INR, Via-USD) to Ether or another Via currency
    function convertFromVia(uint256 amount, bytes32 currency, uint256 ethusd, uint256 viarate) private returns(uint256){
        //if currency to convert from is ether
        if(currency=="ether"){
            uint256 amountInViaUSD = amount * viarate;
            uint256 inEth = amountInViaUSD * (1/ethusd);
            return inEth;
        }
        //else convert to another via currency
        else{
            return(viarate*amount);
        }
    }

    //uses Oraclize to calculate price of 1 year zero coupon bond in currency and for amount to issue to borrower
    //to do : we need to support bonds with tenure different than the default 1 year. 
    function getBondValueToIssue(uint256 amount, bytes32 currency, uint tenure, uint256 ethusd, uint256 viarate) private returns(uint256){
        //to first convert amount of ether passed to this function to USD
        uint256 amountInUSD = (amount/1000000000000000000)*ethusd;
        //to then get Via interest rates from oracle and calculate zero coupon bond price
        if(currency!="Via-USD"){
            return amountInUSD / (1 + viarate) ^ tenure;
        }
        else{
            return amountInUSD / (1 + viarate) ^ tenure;
        }
    }

    //calculate price of redeeming zero coupon bond in currency and for amount to borrower who may redeem before end of year
    function getBondValueToRedeem(uint256 _amount, bytes32 _currency, address _borrower, uint256 ethusd, uint256 viarate) private returns(uint256, uint){
        //find out if bond is present in list of issued bonds
        uint256 toRedeem;
        for(uint p=0; p < loans[msg.sender].length; p++){
            //if bond is found to be issued
            if(loans[msg.sender][p].borrower == _borrower &&
                loans[msg.sender][p].currency == _currency &&
                loans[msg.sender][p].price >= _amount){
                    uint256 timeOfIssue = loans[msg.sender][p].timeOfIssue;
                    //if entire amount is to be redeemed, remove issued bond from store
                    if(loans[msg.sender][p].price - _amount ==0){
                        toRedeem = _amount;
                        delete(loans[msg.sender][p]);
                    }else{
                        //else, reduce outstanding value of bond
                        loans[msg.sender][p].price = loans[msg.sender][p].price - _amount;
                    }
                    return(convertFromVia(toRedeem, _currency, ethusd, viarate), timeOfIssue);
                    //return(convertFromVia(toRedeem, _currency, ethusd, viarate), DayCountConventions.diffTime(now,timeOfIssue));
            }
        }
        return(0,0);
    }

    function storeIssuedBond(address _borrower,
                            bytes32 _currency,
                            uint256 _facevalue,
                            uint256 _viabond,
                            uint256 _amount,
                            bytes32 _collateralCurrency,
                            uint _timeofissue,
                            uint _tenure) private {
        loans[address(this)].push(loan(_borrower,_currency,_facevalue,_viabond,_amount,_collateralCurrency,_timeofissue,_tenure));
    }

}
