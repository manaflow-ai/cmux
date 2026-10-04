import Foundation

/// StoreKit's local verification result for one transaction.
public enum StoreTransactionVerification: Sendable, Equatable {
    /// The signature verified; the transaction may be sent to the server.
    case verified(StoreTransaction)
    /// The signature did not verify. The app never grants, posts or finishes
    /// it; StoreKit keeps it unfinished.
    case unverified(transactionID: UInt64, productID: String)
}
