import Foundation

/// A StoreKit transaction that passed StoreKit's local verification.
///
/// Holds the JWS the server verifies again against Apple's root CA. The live
/// adapter keeps the underlying `Transaction` so
/// ``StoreKitClient/finish(transactionID:)`` can finish it later.
public struct StoreTransaction: Sendable, Equatable, Hashable, Identifiable {
    /// The App Store transaction id.
    public let id: UInt64
    /// The purchased product id.
    public let productID: String
    /// `Transaction.jwsRepresentation`, posted to the server as is.
    public let jwsRepresentation: String
    /// The `appAccountToken` the purchase carried, when it carried one.
    public let appAccountToken: UUID?

    /// Creates a transaction value.
    /// - Parameters:
    ///   - id: The transaction id.
    ///   - productID: The product id.
    ///   - jwsRepresentation: The signed JWS.
    ///   - appAccountToken: The purchase's account token, when present.
    public init(id: UInt64, productID: String, jwsRepresentation: String, appAccountToken: UUID?) {
        self.id = id
        self.productID = productID
        self.jwsRepresentation = jwsRepresentation
        self.appAccountToken = appAccountToken
    }
}
