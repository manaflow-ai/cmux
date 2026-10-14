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
    /// The App Store environment of the transaction: `Production`,
    /// `Sandbox` (TestFlight and App Review), or `Xcode` (a StoreKit
    /// configuration file); nil when StoreKit does not say.
    public let environment: String?

    /// Creates a transaction value.
    /// - Parameters:
    ///   - id: The transaction id.
    ///   - productID: The product id.
    ///   - jwsRepresentation: The signed JWS.
    ///   - appAccountToken: The purchase's account token, when present.
    ///   - environment: The App Store environment, when known.
    public init(
        id: UInt64,
        productID: String,
        jwsRepresentation: String,
        appAccountToken: UUID?,
        environment: String? = nil
    ) {
        self.id = id
        self.productID = productID
        self.jwsRepresentation = jwsRepresentation
        self.appAccountToken = appAccountToken
        self.environment = environment
    }
}
