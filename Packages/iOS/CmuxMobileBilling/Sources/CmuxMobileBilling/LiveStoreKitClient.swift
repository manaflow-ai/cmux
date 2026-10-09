#if canImport(StoreKit)
import Foundation
import StoreKit

/// ``StoreKitClient`` over StoreKit 2.
///
/// An actor so the transactions it hands out stay retrievable for
/// ``finish(transactionID:)``: the model finishes a transaction only after the
/// server accepted it, which can be long after StoreKit delivered it.
public actor LiveStoreKitClient: StoreKitClient {
    /// Delivered but not yet finished transactions, by id.
    private var heldTransactions: [UInt64: Transaction] = [:]

    /// Creates the client.
    public init() {}

    public func products(for ids: [String]) async throws -> [StoreProduct] {
        guard !ids.isEmpty else { return [] }
        let products: [Product]
        do {
            products = try await Product.products(for: ids)
        } catch {
            throw Self.normalized(error)
        }
        return products.map(Self.storeProduct(_:))
    }

    public func purchase(productID: String, appAccountToken: UUID) async throws -> StorePurchaseResult {
        let product: Product
        do {
            guard let found = try await Product.products(for: [productID]).first else {
                throw StoreKitClientError.productUnavailable
            }
            product = found
        } catch let error as StoreKitClientError {
            throw error
        } catch {
            throw Self.normalized(error)
        }
        let result: Product.PurchaseResult
        do {
            result = try await product.purchase(options: [.appAccountToken(appAccountToken)])
        } catch {
            throw Self.normalized(error)
        }
        switch result {
        case .success(let verification):
            return .completed(hold(verification))
        case .pending:
            return .pending
        case .userCancelled:
            return .userCancelled
        @unknown default:
            throw StoreKitClientError.system
        }
    }

    public nonisolated func transactionUpdates() -> AsyncStream<StoreTransactionVerification> {
        AsyncStream { continuation in
            let task = Task { [weak self] in
                for await verification in Transaction.updates {
                    guard let self else { break }
                    continuation.yield(await self.hold(verification))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func unfinishedTransactions() async -> [StoreTransactionVerification] {
        var results: [StoreTransactionVerification] = []
        for await verification in Transaction.unfinished {
            results.append(hold(verification))
        }
        return results
    }

    public func currentEntitlements() async -> [StoreTransactionVerification] {
        var results: [StoreTransactionVerification] = []
        for await verification in Transaction.currentEntitlements {
            results.append(hold(verification))
        }
        return results
    }

    public func syncWithAppStore() async throws {
        do {
            try await AppStore.sync()
        } catch {
            throw Self.normalized(error)
        }
    }

    public func finish(transactionID: UInt64) async {
        if let transaction = heldTransactions.removeValue(forKey: transactionID) {
            await transaction.finish()
            return
        }
        // Not handed out by this process (a relaunch since delivery): look it
        // up among StoreKit's unfinished transactions.
        for await verification in Transaction.unfinished {
            guard case .verified(let transaction) = verification, transaction.id == transactionID else { continue }
            await transaction.finish()
            return
        }
    }

    /// The App Store environment this build buys in: `Production` for App
    /// Store builds, `Sandbox` for TestFlight and App Review, nil for Xcode
    /// testing or when StoreKit cannot tell. Read from the signed
    /// `AppTransaction`, which StoreKit caches after the first read.
    public static func appStoreEnvironment() async -> String? {
        guard case .verified(let appTransaction) = try? await AppTransaction.shared else { return nil }
        switch appTransaction.environment {
        case .production: return "Production"
        case .sandbox: return "Sandbox"
        default: return nil
        }
    }

    /// Records a verified transaction for a later finish and converts it.
    private func hold(_ verification: VerificationResult<Transaction>) -> StoreTransactionVerification {
        switch verification {
        case .verified(let transaction):
            heldTransactions[transaction.id] = transaction
            return .verified(StoreTransaction(
                id: transaction.id,
                productID: transaction.productID,
                jwsRepresentation: verification.jwsRepresentation,
                appAccountToken: transaction.appAccountToken
            ))
        case .unverified(let transaction, _):
            return .unverified(transactionID: transaction.id, productID: transaction.productID)
        }
    }

    private static func storeProduct(_ product: Product) -> StoreProduct {
        StoreProduct(
            id: product.id,
            displayName: product.displayName,
            productDescription: product.description,
            displayPrice: product.displayPrice,
            periodUnitName: product.subscription.map { $0.subscriptionPeriod.unit.localizedDescription }
        )
    }

    private static func normalized(_ error: any Error) -> StoreKitClientError {
        if let error = error as? StoreKitClientError { return error }
        if let error = error as? StoreKitError {
            switch error {
            case .userCancelled: return .userCancelled
            case .networkError: return .network
            case .notAvailableInStorefront: return .productUnavailable
            default: return .system
            }
        }
        if let error = error as? Product.PurchaseError {
            switch error {
            case .productUnavailable: return .productUnavailable
            case .purchaseNotAllowed: return .purchasesNotAllowed
            default: return .system
            }
        }
        if error is URLError { return .network }
        return .system
    }
}
#endif
