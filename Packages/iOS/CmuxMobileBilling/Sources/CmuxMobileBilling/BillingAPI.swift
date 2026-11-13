import Foundation

/// The cmux web routes the phone uses for App Store billing.
///
/// ``HTTPBillingAPI`` is the production conformance; tests supply a fake so
/// the purchase state machine runs without a network.
public protocol BillingAPI: Sendable {
    /// `POST /api/billing/apple/account-token`.
    /// - Returns: The account's purchase token, eligibility, plan and products.
    /// - Throws: ``BillingAPIError``.
    func accountToken() async throws -> BillingAccount

    /// `POST /api/billing/apple/transactions` with one StoreKit 2 JWS.
    /// - Parameter signedTransactionInfo: `Transaction.jwsRepresentation`.
    /// - Returns: The plan the server applied.
    /// - Throws: ``BillingAPIError``; any throw means the server did not
    ///   accept the transaction and it must not be finished.
    func submitTransaction(signedTransactionInfo: String) async throws -> BillingTransactionReceipt
}
