/**
 *  @authors: [@eburgos, @n1c01a5]
 *  @reviewers: [@unknownunknown1*, @clesaege*, @ferittuncer]
 *  @auditors: []
 *  @bounties: []
 *  @deployments: []
 */

pragma solidity ^0.4.24;

import "./Arbitrator.sol";

contract MultipleArbitrableTransaction {

    // **************************** //
    // *    Contract variables    * //
    // **************************** //

    uint8 constant AMOUNT_OF_CHOICES = 2;
    uint8 constant BUYER_WINS = 1;
    uint8 constant SELLER_WINS = 2;

    enum Party {Seller, Buyer}
    enum Status {NoDispute, WaitingSeller, WaitingBuyer, DisputeCreated, Resolved}

    struct Transaction {
        address seller;
        address buyer;
        uint256 amount;
        uint256 timeoutPayment; // Time in seconds after which the transaction can be automatically executed if not disputed.
        uint disputeId; // If dispute exists, the ID of the dispute.
        uint sellerFee; // Total fees paid by the seller.
        uint buyerFee; // Total fees paid by the buyer.
        uint lastInteraction; // Last interaction for the dispute procedure.
        Status status;
        uint arbitrationCost;
    }

    Transaction[] public transactions;
    bytes public arbitratorExtraData; // Extra data to set up the arbitration.
    Arbitrator public arbitrator; // Address of the arbitrator contract.
    uint public feeTimeout; // Time in seconds a party can take to pay arbitration fees before being considered unresponding and lose the dispute.


    mapping (uint => uint) public disputeIDtoTransactionID; // One-to-one relationship between the dispute and the transaction.

    // **************************** //
    // *          Events          * //
    // **************************** //

    /** @dev To be emmited when meta-evidence is submitted.
     *  @param _metaEvidenceID Unique identifier of meta-evidence. Should be the transactionID.
     *  @param _evidence A link to the meta-evidence JSON.
     */
    event MetaEvidence(uint indexed _metaEvidenceID, string _evidence);

    /** @dev Indicate that a party has to pay a fee or would otherwise be considered as losing.
     *  @param _transactionID The index of the transaction.
     *  @param _party The party who has to pay.
     */
    event HasToPayFee(uint indexed _transactionID, Party _party);

    /** @dev To be raised when evidence are submitted. Should point to the ressource (evidences are not to be stored on chain due to gas considerations).
     *  @param _arbitrator The arbitrator of the contract.
     *  @param _disputeID ID of the dispute in the Arbitrator contract.
     *  @param _party The address of the party submiting the evidence. Note that 0 is kept for evidences not submitted by any party.
     *  @param _evidence A link to evidence or if it is short the evidence itself. Can be web link ("http://X"), IPFS ("ipfs:/X") or another storing service (using the URI, see https://en.wikipedia.org/wiki/Uniform_Resource_Identifier ). One usecase of short evidence is to include the hash of the plain English contract.
     */
    event Evidence(Arbitrator indexed _arbitrator, uint indexed _disputeID, address indexed _party, string _evidence);

    /** @dev To be emmited when a dispute is created to link the correct meta-evidence to the disputeID.
     *  @param _arbitrator The arbitrator of the contract.
     *  @param _disputeID ID of the dispute in the Arbitrator contract.
     *  @param _metaEvidenceID Unique identifier of meta-evidence. Should be the transactionID.
     */
    event Dispute(Arbitrator indexed _arbitrator, uint indexed _disputeID, uint _metaEvidenceID);

    /** @dev To be raised when a ruling is given.
     *  @param _arbitrator The arbitrator giving the ruling.
     *  @param _disputeID ID of the dispute in the Arbitrator contract.
     *  @param _ruling The ruling which was given.
     */
    event Ruling(Arbitrator indexed _arbitrator, uint indexed _disputeID, uint _ruling);

    // **************************** //
    // *    Arbitrable functions  * //
    // *    Modifying the state   * //
    // **************************** //

    /** @dev Constructor.
     *  @param _arbitrator The arbitrator of the contract.
     *  @param _arbitratorExtraData Extra data for the arbitrator.
     *  @param _feeTimeout Arbitration fee timeout for the parties.
     */
    constructor (
        Arbitrator _arbitrator,
        bytes _arbitratorExtraData,
        uint _feeTimeout
    ) public {
        arbitrator = _arbitrator;
        arbitratorExtraData = _arbitratorExtraData;
        feeTimeout = _feeTimeout;
    }

    /** @dev Create a transaction.
     *  @param _timeoutPayment Time after which a party can automatically execute the arbitrable transaction.
     *  @param _seller The recipient of the transaction.
     *  @param _metaEvidence Link to the meta-evidence.
     *  @return transactionID The index of the transaction.
     */
    function createTransaction(
        uint _timeoutPayment,
        address _seller,
        string _metaEvidence
    ) public payable returns (uint transactionID) {
        transactions.push(Transaction({
            seller: _seller,
            buyer: msg.sender,
            amount: msg.value,
            timeoutPayment: _timeoutPayment,
            disputeId: 0,
            sellerFee: 0,
            buyerFee: 0,
            lastInteraction: now,
            status: Status.NoDispute,
            arbitrationCost: 0
        }));
        emit MetaEvidence(transactions.length - 1, _metaEvidence);
        return transactions.length - 1;
    }

    /** @dev Pay seller. To be called if the good or service is provided.
     *  @param _transactionID The index of the transaction.
     *  @param _amount Amount to pay in wei.
     */
    function pay(uint _transactionID, uint _amount) public {
        Transaction storage transaction = transactions[_transactionID];
        require(transaction.buyer == msg.sender, "The caller must be the buyer.");
        require(transaction.status == Status.NoDispute, "The transaction can't be disputed.");
        require(_amount <= transaction.amount, "The amount paid has to be less than or equal to the transaction.");

        transaction.seller.transfer(_amount);
        transaction.amount -= _amount;
    }

    /** @dev Reimburse buyer. To be called if the good or service can't be fully provided.
     *  @param _transactionID The index of the transaction.
     *  @param _amountReimbursed Amount to reimburse in wei.
     */
    function reimburse(uint _transactionID, uint _amountReimbursed) public {
        Transaction storage transaction = transactions[_transactionID];
        require(transaction.seller == msg.sender, "The caller must be the seller.");
        require(transaction.status == Status.NoDispute, "The transaction can't be disputed.");
        require(_amountReimbursed <= transaction.amount, "The amount reimbursed has to be less or equal than the transaction.");

        transaction.buyer.transfer(_amountReimbursed);
        transaction.amount -= _amountReimbursed;
    }

    /** @dev Transfer the transaction's amount to the seller if the timeout has passed.
     *  @param _transactionID The index of the transaction.
     */
    function executeTransaction(uint _transactionID) public {
        Transaction storage transaction = transactions[_transactionID];
        require(now - transaction.lastInteraction >= transaction.timeoutPayment, "The timeout has not passed yet.");
        require(transaction.status == Status.NoDispute, "The transaction can't be disputed.");

        transaction.seller.transfer(transaction.amount);
        transaction.amount = 0;

        transaction.status = Status.Resolved;
    }

    /** @dev Reimburse buyer if seller fails to pay the fee.
     *  @param _transactionID The index of the transaction.
     */
    function timeOutByBuyer(uint _transactionID) public {
        Transaction storage transaction = transactions[_transactionID];

        require(transaction.status == Status.WaitingSeller, "The transaction is not waiting on the seller.");
        require(now - transaction.lastInteraction >= feeTimeout, "Timeout time has not passed yet.");

        executeRuling(_transactionID, BUYER_WINS);
    }

    /** @dev Pay seller if buyer fails to pay the fee.
     *  @param _transactionID The index of the transaction.
     */
    function timeOutBySeller(uint _transactionID) public {
        Transaction storage transaction = transactions[_transactionID];

        require(transaction.status == Status.WaitingBuyer, "The transaction is not waiting on the buyer.");
        require(now - transaction.lastInteraction >= feeTimeout, "Timeout time has not passed yet.");

        executeRuling(_transactionID, SELLER_WINS);
    }

    /** @dev Pay the arbitration fee to raise a dispute. To be called by the buyer. UNTRUSTED.
     *  Note that this function mirror payArbitrationFeeBySeller.
     *  @param _transactionID The index of the transaction.
     */
    function payArbitrationFeeByBuyer(uint _transactionID) public payable {
        Transaction storage transaction = transactions[_transactionID];
        uint arbitrationCost = arbitrator.arbitrationCost(arbitratorExtraData);

        require(transaction.status < Status.DisputeCreated, "Dispute has already been created or because the transaction has been executed.");
        require(msg.sender == transaction.buyer, "The caller must be the buyer.");

        transaction.buyerFee += msg.value;
        // Require that the total paid to be at least the arbitration cost.
        require(transaction.buyerFee >= arbitrationCost, "The buyer fee must cover arbitration costs.");

        transaction.lastInteraction = now;
        // The seller still has to pay. This can also happens if he has paid, but arbitrationCost has increased.
        if (transaction.sellerFee < arbitrationCost) {
            transaction.status = Status.WaitingSeller;
            emit HasToPayFee(_transactionID, Party.Seller);
        } else { // The buyer has also paid the fee. We create the dispute
            raiseDispute(_transactionID, arbitrationCost);
        }
    }

    /** @dev Pay the arbitration fee to raise a dispute. To be called by the seller. UNTRUSTED.
     *  Note that the arbitrator can have createDispute throw, which will make this function throw and therefore lead to a party being timed-out.
     *  This is not a vulnerability as the arbitrator can rule in favor of one party anyway.
     *  @param _transactionID The index of the transaction.
     */
    function payArbitrationFeeBySeller(uint _transactionID) public payable {
        Transaction storage transaction = transactions[_transactionID];
        uint arbitrationCost = arbitrator.arbitrationCost(arbitratorExtraData);

        require(transaction.status < Status.DisputeCreated, "Dispute has already been created or because the transaction has been executed.");
        require(msg.sender == transaction.seller, "The caller must be the seller.");

        transaction.sellerFee += msg.value;
        // Require that the total pay at least the arbitration cost.
        require(transaction.sellerFee >= arbitrationCost, "The seller fee must cover arbitration costs.");

        transaction.lastInteraction = now;
        // The buyer still has to pay. This can also happens if he has paid, but arbitrationCost has increased.
        if (transaction.buyerFee < arbitrationCost) {
            transaction.status = Status.WaitingBuyer;
            emit HasToPayFee(_transactionID, Party.Buyer);
        } else { // The seller has also paid the fee. We create the dispute
            raiseDispute(_transactionID, arbitrationCost);
        }
    }

    /** @dev Create a dispute. UNTRUSTED.
     *  @param _transactionID The index of the transaction.
     *  @param _arbitrationCost Amount to pay the arbitrator.
     */
    function raiseDispute(uint _transactionID, uint _arbitrationCost) internal {
        Transaction storage transaction = transactions[_transactionID];
        transaction.status = Status.DisputeCreated;
        transaction.arbitrationCost = _arbitrationCost;
        transaction.disputeId = arbitrator.createDispute.value(_arbitrationCost)(AMOUNT_OF_CHOICES, arbitratorExtraData);
        disputeIDtoTransactionID[transaction.disputeId] = _transactionID;
        emit Dispute(arbitrator, transaction.disputeId, _transactionID);

        // Refund seller if it overpaid.
        if (transaction.sellerFee > _arbitrationCost) {
            uint extraFeeSeller = transaction.sellerFee - _arbitrationCost;
            transaction.sellerFee = _arbitrationCost;
            transaction.seller.send(extraFeeSeller);
        }

        // Refund buyer if it overpaid.
        if (transaction.buyerFee > _arbitrationCost) {
            uint extraFeeBuyer = transaction.buyerFee - _arbitrationCost;
            transaction.buyerFee = _arbitrationCost;
            transaction.buyer.send(extraFeeBuyer);
        }
    }

    /** @dev Submit a reference to evidence. EVENT.
     *  @param _transactionID The index of the transaction.
     *  @param _evidence A link to an evidence using its URI.
     */
    function submitEvidence(uint _transactionID, string _evidence) public {
        Transaction storage transaction = transactions[_transactionID];
        require(msg.sender == transaction.buyer || msg.sender == transaction.seller, "The caller must be the buyer or the seller.");

        require(transaction.status >= Status.DisputeCreated, "The dispute has not been created yet.");
        emit Evidence(arbitrator, transaction.disputeId, msg.sender, _evidence);
    }

    /** @dev Appeal an appealable ruling.
     *  Transfer the funds to the arbitrator.
     *  Note that no checks are required as the checks are done by the arbitrator.
     *  @param _transactionID The index of the transaction.
     */
    function appeal(uint _transactionID) public payable {
        Transaction storage transaction = transactions[_transactionID];

        arbitrator.appeal.value(msg.value)(transaction.disputeId, arbitratorExtraData);
    }

    /** @dev Give a ruling for a dispute. Must be called by the arbitrator.
     *  The purpose of this function is to ensure that the address calling it has the right to rule on the contract.
     *  @param _disputeID ID of the dispute in the Arbitrator contract.
     *  @param _ruling Ruling given by the arbitrator. Note that 0 is reserved for "Not able/wanting to make a decision".
     */
    function rule(uint _disputeID, uint _ruling) public {
        uint transactionID = disputeIDtoTransactionID[_disputeID];
        Transaction storage transaction = transactions[transactionID];
        require(msg.sender == address(arbitrator), "The caller must be the arbitrator.");
        require(transaction.status == Status.DisputeCreated, "The dispute has already been resolved.");

        emit Ruling(Arbitrator(msg.sender), _disputeID, _ruling);

        executeRuling(transactionID, _ruling);
    }

    /** @dev Execute a ruling of a dispute. It reimburses the fee to the winning party.
     *  @param _transactionID The index of the transaction.
     *  @param _ruling Ruling given by the arbitrator. 1 : Reimburse the buyer. 2 : Pay the seller.
     */
    function executeRuling(uint _transactionID, uint _ruling) internal {
        Transaction storage transaction = transactions[_transactionID];
        require(_ruling <= AMOUNT_OF_CHOICES, "Invalid ruling.");

        // Give the arbitration fee back.
        // Note that we use send to prevent a party from blocking the execution.
        if (_ruling == SELLER_WINS) {
            transaction.seller.send(transaction.sellerFee + transaction.amount);
        } else if (_ruling == BUYER_WINS) {
            transaction.buyer.send(transaction.buyerFee + transaction.amount);
        } else {
            uint split_amount = (transaction.sellerFee + transaction.buyerFee - transaction.arbitrationCost + transaction.amount) / 2;
            transaction.buyer.send(split_amount);
            transaction.seller.send(split_amount);
        }

        transaction.amount = 0;
        transaction.sellerFee = 0;
        transaction.buyerFee = 0;
        transaction.status = Status.Resolved;
    }

    // **************************** //
    // *     Constant getters     * //
    // **************************** //

    /** @dev Getter to know the count of transactions.
     *  @return countTransactions The count of transactions.
     */
    function getCountTransactions() public view returns (uint countTransactions) {
        return transactions.length;
    }

    /** @dev Get IDs for transactions where the specified address is the buyer and/or the seller.
     *  This function must be used by the UI and not by other smart contracts.
     *  Note that the complexity is O(t), where t is amount of arbitrable transactions.
     *  @param _address The specified address.
     *  @return transactionIDs The transaction IDs.
     */
    function getTransactionIDsByAddress(address _address) public view returns (uint[] transactionIDs) {
        uint count = 0;
        for (uint i = 0; i < transactions.length; i++) {
            if (transactions[i].seller == _address || transactions[i].buyer == _address)
                count++;
        }

        transactionIDs = new uint[](count);

        count = 0;

        for (uint j = 0; j < transactions.length; j++) {
            if (transactions[j].seller == _address || transactions[j].buyer == _address)
                transactionIDs[count++] = j;
        }
    }
}
