import Foundation

/// The StoreKit 2 operations ``BillingModel`` uses.
///
/// ``LiveStoreKitClient`` is the production conformance; unit tests pass a
/// fake, so no test touches real StoreKit.
public protocol StoreKitClient: Sendable {
    /// Loads products for the given ids. Unknown ids are omitted.
    /// - Parameter ids: App Store product ids.
    /// - Returns: The products StoreKit knows.
    /// - Throws: A StoreKit or network error.
    func products(for ids: [String]) async throws -> [StoreProduct]

    /// Starts a purchase that carries `appAccountToken`.
    /// - Parameters:
    ///   - productID: The product to buy.
    ///   - appAccountToken: The server-minted account token.
    /// - Returns: The purchase outcome.
    /// - Throws: ``StoreKitClientError`` or a StoreKit error.
    func purchase(productID: String, appAccountToken: UUID) async throws -> StorePurchaseResult

    /// Starts a purchase that carries `appAccountToken` and, when given, the
    /// server-signed introductory offer eligibility. A default implementation
    /// ignores the JWS.
    func purchase(productID: String, appAccountToken: UUID, introductoryOfferJWS: String?) async throws
        -> StorePurchaseResult

    /// The `AppTransaction` id (iOS 18.4 and later); nil when unavailable.
    /// Defaults to nil.
    func appTransactionID() async -> String?

    /// Transactions created outside a direct purchase call: renewals,
    /// approved Ask to Buy requests, purchases on other devices, refunds.
    /// - Returns: A stream that lasts for the app's lifetime.
    func transactionUpdates() -> AsyncStream<StoreTransactionVerification>

    /// Transactions StoreKit delivered but the app has not finished yet.
    /// - Returns: The unfinished transactions.
    func unfinishedTransactions() async -> [StoreTransactionVerification]

    /// The latest transaction for every active subscription.
    /// - Returns: The current entitlements.
    func currentEntitlements() async -> [StoreTransactionVerification]

    /// `AppStore.sync()`: asks the App Store for the newest transactions.
    /// May show an Apple ID sign-in prompt.
    /// - Throws: ``StoreKitClientError/userCancelled`` when the user cancels
    ///   that prompt, or a StoreKit error.
    func syncWithAppStore() async throws

    /// The App Store storefront country code (ISO 3166-1 alpha-3, such as
    /// `USA`), for analytics.
    /// - Returns: The country code, or nil when StoreKit has no storefront.
    func storefrontCountryCode() async -> String?

    /// Finishes a transaction after the server accepted it.
    /// - Parameter transactionID: The transaction to finish.
    func finish(transactionID: UInt64) async
}

extension StoreKitClient {
    /// Starts a purchase; with `introductoryOfferJWS`, passes the server's
    /// signed introductory offer eligibility (iOS 18.4 and later).
    /// Conformances that cannot pass it ignore it.
    public func purchase(
        productID: String,
        appAccountToken: UUID,
        introductoryOfferJWS: String?
    ) async throws -> StorePurchaseResult {
        try await purchase(productID: productID, appAccountToken: appAccountToken)
    }

    /// The `AppTransaction` id (iOS 18.4 and later), which the server needs
    /// to sign introductory offer eligibility; nil when unavailable.
    public func appTransactionID() async -> String? { nil }
}

