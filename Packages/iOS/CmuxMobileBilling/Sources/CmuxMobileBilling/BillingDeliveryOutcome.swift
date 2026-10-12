import Foundation

/// The result of sending one verified transaction to the server.
public enum BillingDeliveryOutcome: Sendable, Equatable {
    /// The server accepted the transaction, and it was then finished.
    case accepted(BillingTransactionReceipt)
    /// The server did not accept it yet (network, 5xx, signed out). The
    /// transaction stays unfinished, so StoreKit redelivers it and a later
    /// retry posts it again.
    case deferred(BillingFailure)
    /// The server refused it for good (see ``BillingFailure/isPermanentRejection``).
    /// It stays unfinished so another account can still claim it, but this
    /// session does not re-post it automatically.
    case rejected(BillingFailure)
}
