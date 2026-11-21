import Foundation

/// The outcome of `Product.purchase(options:)`.
public enum StorePurchaseResult: Sendable, Equatable {
    /// The App Store completed the purchase; the transaction must still be
    /// delivered to the server before it is finished.
    case completed(StoreTransactionVerification)
    /// The purchase waits for approval (Ask to Buy, Strong Customer
    /// Authentication); the result arrives later through
    /// ``StoreKitClient/transactionUpdates()``.
    case pending
    /// The user dismissed the purchase sheet.
    case userCancelled
}
