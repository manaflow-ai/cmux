#if os(iOS)
import Foundation
import CmuxMobileSystemUIBridge

/// ``StoreKitClient`` over StoreKit 2, reached through
/// CmuxMobileSystemUI.framework (``SystemUI/provider``'s store): linked,
/// StoreKit costs the app about 1.55 s before `main` on a cold launch, so this
/// module does not import it. ``finish(transactionID:)`` finds the
/// transaction among StoreKit's unfinished ones: the model finishes a
/// transaction only after the server accepted it, which can be long after
/// StoreKit delivered it (a relaunch since is fine).
///
/// Without the framework (it failed to load), product loads, purchases and
/// sync throw ``StoreKitClientError/system``, the transaction lists are empty
/// and the update stream finishes at once.
public actor LiveStoreKitClient: StoreKitClient {
    /// Creates the client. Loads nothing until the first call.
    public init() {}

    public func products(for ids: [String]) async throws -> [StoreProduct] {
        guard !ids.isEmpty else { return [] }
        guard let store = Self.store else { throw StoreKitClientError.system }
        let (products, failure) = await withCheckedContinuation { (continuation: CheckedContinuation<([StoreProduct], SystemUIStoreFailure), Never>) in
            store.products(identifiers: ids) { products, failure in
                continuation.resume(returning: (products.map(Self.storeProduct(_:)), failure))
            }
        }
        if let error = Self.error(failure) { throw error }
        return products
    }

    public func purchase(productID: String, appAccountToken: UUID) async throws -> StorePurchaseResult {
        guard let store = Self.store else { throw StoreKitClientError.system }
        let (outcome, transaction, failure) = await withCheckedContinuation { (continuation: CheckedContinuation<(SystemUIPurchaseOutcome, StoreTransactionVerification?, SystemUIStoreFailure), Never>) in
            store.purchase(productID: productID, appAccountToken: appAccountToken) { outcome, transaction, failure in
                continuation.resume(returning: (outcome, transaction.map(Self.verification(_:)), failure))
            }
        }
        if let error = Self.error(failure) { throw error }
        switch outcome {
        case .completed:
            guard let transaction else { throw StoreKitClientError.system }
            return .completed(transaction)
        case .pending:
            return .pending
        case .userCancelled:
            return .userCancelled
        }
    }

    /// The first call loads the framework off the calling thread: the model
    /// calls this from the main actor at launch, and loading links StoreKit.
    public nonisolated func transactionUpdates() -> AsyncStream<StoreTransactionVerification> {
        AsyncStream { continuation in
            let observation = UpdatesObservation()
            continuation.onTermination = { _ in observation.cancel() }
            Task.detached {
                guard let store = Self.store else {
                    continuation.finish()
                    return
                }
                observation.attach(store.observeTransactionUpdates { transaction in
                    continuation.yield(Self.verification(transaction))
                })
            }
        }
    }

    public func unfinishedTransactions() async -> [StoreTransactionVerification] {
        guard let store = Self.store else { return [] }
        return await withCheckedContinuation { continuation in
            store.unfinishedTransactions { transactions in
                continuation.resume(returning: transactions.map(Self.verification(_:)))
            }
        }
    }

    public func currentEntitlements() async -> [StoreTransactionVerification] {
        guard let store = Self.store else { return [] }
        return await withCheckedContinuation { continuation in
            store.currentEntitlements { transactions in
                continuation.resume(returning: transactions.map(Self.verification(_:)))
            }
        }
    }

    public func syncWithAppStore() async throws {
        guard let store = Self.store else { throw StoreKitClientError.system }
        let failure = await withCheckedContinuation { continuation in
            store.syncWithAppStore { failure in
                continuation.resume(returning: failure)
            }
        }
        if let error = Self.error(failure) { throw error }
    }

    public func storefrontCountryCode() async -> String? {
        guard let store = Self.store else { return nil }
        return await withCheckedContinuation { continuation in
            store.storefrontCountryCode { code in
                continuation.resume(returning: code)
            }
        }
    }

    public func finish(transactionID: UInt64) async {
        guard let store = Self.store else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            store.finish(transactionID: transactionID) {
                continuation.resume()
            }
        }
    }

    /// The App Store environment this build buys in: `Production` for App
    /// Store builds, `Sandbox` for TestFlight and App Review, nil for Xcode
    /// testing, when StoreKit cannot tell, or without the framework. Read from
    /// the signed `AppTransaction`, which StoreKit caches after the first read.
    public static func appStoreEnvironment() async -> String? {
        guard let store = Self.store else { return nil }
        return await withCheckedContinuation { continuation in
            store.appStoreEnvironment { environment in
                continuation.resume(returning: environment)
            }
        }
    }

    /// The framework's store; nil when the framework did not load.
    private static var store: (any SystemUIStore)? {
        SystemUI.provider?.store
    }

    private static func storeProduct(_ product: any SystemUIStoreProduct) -> StoreProduct {
        StoreProduct(
            id: product.productID,
            displayName: product.displayName,
            productDescription: product.productDescription,
            displayPrice: product.displayPrice,
            periodUnitName: product.periodUnitName,
            price: product.price?.decimalValue,
            currencyCode: product.currencyCode,
            monthlyEquivalentDisplayPrice: product.monthlyEquivalentDisplayPrice
        )
    }

    private static func verification(_ transaction: any SystemUIStoreTransaction) -> StoreTransactionVerification {
        guard transaction.isVerified else {
            return .unverified(transactionID: transaction.transactionID, productID: transaction.productID)
        }
        return .verified(StoreTransaction(
            id: transaction.transactionID,
            productID: transaction.productID,
            jwsRepresentation: transaction.jwsRepresentation,
            appAccountToken: transaction.appAccountToken,
            environment: transaction.environment
        ))
    }

    /// The framework's failure as the error this client throws; nil for none.
    private static func error(_ failure: SystemUIStoreFailure) -> StoreKitClientError? {
        switch failure {
        case .none: nil
        case .productUnavailable: .productUnavailable
        case .userCancelled: .userCancelled
        case .purchasesNotAllowed: .purchasesNotAllowed
        case .network: .network
        case .system: .system
        }
    }
}

/// The framework's `Transaction.updates` observation for one stream, which
/// may end before the observation starts: then it is cancelled on attach.
private final class UpdatesObservation: @unchecked Sendable {
    // @unchecked: `lock` guards both fields; the handle's `cancel()` only
    // cancels a task, so any thread may call it.
    private let lock = NSLock()
    private var handle: (any SystemUICancellable)?
    private var cancelled = false

    func attach(_ handle: any SystemUICancellable) {
        let cancelNow = lock.withLock {
            if cancelled { return true }
            self.handle = handle
            return false
        }
        if cancelNow { handle.cancel() }
    }

    func cancel() {
        let handle = lock.withLock {
            cancelled = true
            defer { self.handle = nil }
            return self.handle
        }
        handle?.cancel()
    }
}
#endif
