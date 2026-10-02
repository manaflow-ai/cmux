import Foundation

/// The result of sending one verified transaction to the server.
public enum BillingDeliveryOutcome: Sendable, Equatable {
    /// The server accepted the transaction, and it was then finished.
    case accepted(BillingTransactionReceipt)
    /// The server did not accept it. The transaction stays unfinished, so
    /// StoreKit redelivers it and a later retry posts it again.
    case deferred(BillingFailure)
}
