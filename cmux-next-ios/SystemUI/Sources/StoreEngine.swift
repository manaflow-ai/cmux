import Foundation
import StoreKit
import UIKit

/// ``SystemUIStore`` over StoreKit 2: the logic the app's `LiveStoreKitClient`
/// had when it imported StoreKit itself. Each call runs on ``StoreCore`` and
/// completes on whatever thread that leaves it on.
final class StoreEngine: NSObject, SystemUIStore, @unchecked Sendable {
    // @unchecked: the only state is the actor below.
    private let core = StoreCore()

    func products(
        identifiers: [String],
        completion: @escaping @Sendable ([any SystemUIStoreProduct], SystemUIStoreFailure) -> Void
    ) {
        let core = self.core
        Task {
            let (products, failure) = await core.products(for: identifiers)
            completion(products, failure)
        }
    }

    func purchase(
        productID: String,
        appAccountToken: UUID,
        completion: @escaping @Sendable (SystemUIPurchaseOutcome, (any SystemUIStoreTransaction)?, SystemUIStoreFailure) -> Void
    ) {
        let core = self.core
        Task {
            let (outcome, transaction, failure) = await core.purchase(productID: productID, appAccountToken: appAccountToken)
            completion(outcome, transaction, failure)
        }
    }

    func observeTransactionUpdates(
        _ handler: @escaping @Sendable (any SystemUIStoreTransaction) -> Void
    ) -> any SystemUICancellable {
        let core = self.core
        let task = Task {
            for await verification in Transaction.updates {
                handler(await core.hold(verification))
            }
        }
        return TaskCancellable(task)
    }

    func unfinishedTransactions(completion: @escaping @Sendable ([any SystemUIStoreTransaction]) -> Void) {
        let core = self.core
        Task { completion(await core.unfinishedTransactions()) }
    }

    func currentEntitlements(completion: @escaping @Sendable ([any SystemUIStoreTransaction]) -> Void) {
        let core = self.core
        Task { completion(await core.currentEntitlements()) }
    }

    func syncWithAppStore(completion: @escaping @Sendable (SystemUIStoreFailure) -> Void) {
        let core = self.core
        Task { completion(await core.syncWithAppStore()) }
    }

    func storefrontCountryCode(completion: @escaping @Sendable (String?) -> Void) {
        Task { completion(await Storefront.current?.countryCode) }
    }

    func finish(transactionID: UInt64, completion: @escaping @Sendable () -> Void) {
        let core = self.core
        Task {
            await core.finish(transactionID: transactionID)
            completion()
        }
    }

    func appStoreEnvironment(completion: @escaping @Sendable (String?) -> Void) {
        Task { completion(await StoreCore.appStoreEnvironment()) }
    }
}

/// The store's state: the transactions it handed out, kept for
/// ``finish(transactionID:)`` (the app finishes one only after its server
/// accepted it, which can be long after StoreKit delivered it).
actor StoreCore {
    /// Delivered but not yet finished transactions, by id.
    private var heldTransactions: [UInt64: Transaction] = [:]

    func products(for ids: [String]) async -> ([StoreProductObject], SystemUIStoreFailure) {
        guard !ids.isEmpty else { return ([], .none) }
        do {
            let products = try await Product.products(for: ids)
            return (products.map(StoreProductObject.init(product:)), .none)
        } catch {
            return ([], Self.failure(error))
        }
    }

    /// The outcome is meaningful only when the failure is ``SystemUIStoreFailure/none``.
    func purchase(
        productID: String,
        appAccountToken: UUID
    ) async -> (SystemUIPurchaseOutcome, StoreTransactionObject?, SystemUIStoreFailure) {
        let product: Product
        do {
            guard let found = try await Product.products(for: [productID]).first else {
                return (.completed, nil, .productUnavailable)
            }
            product = found
        } catch {
            return (.completed, nil, Self.failure(error))
        }
        let result: Product.PurchaseResult
        do {
            result = try await product.purchase(options: [.appAccountToken(appAccountToken)])
        } catch {
            return (.completed, nil, Self.failure(error))
        }
        switch result {
        case .success(let verification):
            return (.completed, hold(verification), .none)
        case .pending:
            return (.pending, nil, .none)
        case .userCancelled:
            return (.userCancelled, nil, .none)
        @unknown default:
            return (.completed, nil, .system)
        }
    }

    func unfinishedTransactions() async -> [StoreTransactionObject] {
        var results: [StoreTransactionObject] = []
        for await verification in Transaction.unfinished {
            results.append(hold(verification))
        }
        return results
    }

    func currentEntitlements() async -> [StoreTransactionObject] {
        var results: [StoreTransactionObject] = []
        for await verification in Transaction.currentEntitlements {
            results.append(hold(verification))
        }
        return results
    }

    func syncWithAppStore() async -> SystemUIStoreFailure {
        do {
            try await AppStore.sync()
            return .none
        } catch {
            return Self.failure(error)
        }
    }

    func finish(transactionID: UInt64) async {
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
    static func appStoreEnvironment() async -> String? {
        guard case .verified(let appTransaction) = try? await AppTransaction.shared else { return nil }
        switch appTransaction.environment {
        case .production: return "Production"
        case .sandbox: return "Sandbox"
        default: return nil
        }
    }

    /// Records a verified transaction for a later finish and converts it.
    func hold(_ verification: VerificationResult<Transaction>) -> StoreTransactionObject {
        switch verification {
        case .verified(let transaction):
            heldTransactions[transaction.id] = transaction
            return StoreTransactionObject(
                isVerified: true,
                transactionID: transaction.id,
                productID: transaction.productID,
                jwsRepresentation: verification.jwsRepresentation,
                appAccountToken: transaction.appAccountToken,
                environment: Self.environmentName(transaction.environment)
            )
        case .unverified(let transaction, _):
            return StoreTransactionObject(
                isVerified: false,
                transactionID: transaction.id,
                productID: transaction.productID,
                jwsRepresentation: "",
                appAccountToken: nil,
                environment: nil
            )
        }
    }

    private static func environmentName(_ environment: AppStore.Environment) -> String? {
        switch environment {
        case .production: "Production"
        case .sandbox: "Sandbox"
        case .xcode: "Xcode"
        default: nil
        }
    }

    private static func failure(_ error: any Error) -> SystemUIStoreFailure {
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

/// A StoreKit `Product`, converted.
final class StoreProductObject: NSObject, SystemUIStoreProduct, @unchecked Sendable {
    // @unchecked: immutable after init (NSDecimalNumber is immutable).
    let productID: String
    let displayName: String
    let productDescription: String
    let displayPrice: String
    let periodUnitName: String?
    let price: NSDecimalNumber?
    let currencyCode: String?
    let monthlyEquivalentDisplayPrice: String?

    init(product: Product) {
        let period = product.subscription?.subscriptionPeriod
        let isYearly = period.map { $0.unit == .year && $0.value == 1 } ?? false
        productID = product.id
        displayName = product.displayName
        productDescription = product.description
        displayPrice = product.displayPrice
        periodUnitName = period.map { $0.unit.localizedDescription }
        price = NSDecimalNumber(decimal: product.price)
        currencyCode = product.priceFormatStyle.currencyCode
        monthlyEquivalentDisplayPrice = isYearly ? (product.price / 12).formatted(product.priceFormatStyle) : nil
    }
}

/// A StoreKit `VerificationResult<Transaction>`, converted.
final class StoreTransactionObject: NSObject, SystemUIStoreTransaction, Sendable {
    let isVerified: Bool
    let transactionID: UInt64
    let productID: String
    let jwsRepresentation: String
    let appAccountToken: UUID?
    let environment: String?

    init(
        isVerified: Bool,
        transactionID: UInt64,
        productID: String,
        jwsRepresentation: String,
        appAccountToken: UUID?,
        environment: String?
    ) {
        self.isVerified = isVerified
        self.transactionID = transactionID
        self.productID = productID
        self.jwsRepresentation = jwsRepresentation
        self.appAccountToken = appAccountToken
        self.environment = environment
    }
}

/// Cancels a task.
final class TaskCancellable: NSObject, SystemUICancellable, Sendable {
    private let task: Task<Void, Never>

    init(_ task: Task<Void, Never>) {
        self.task = task
    }

    func cancel() {
        task.cancel()
    }
}

/// The App Store's own sheets.
@MainActor
enum StoreSheets {
    /// `AppStore.showManageSubscriptions(in:)`.
    static func showManageSubscriptions(in scene: UIWindowScene, completion: @escaping ((any Error)?) -> Void) {
        let completion = UncheckedSendable(completion)
        Task { @MainActor in
            do {
                try await AppStore.showManageSubscriptions(in: scene)
                completion.value(nil)
            } catch {
                completion.value(error)
            }
        }
    }

    /// `Transaction.beginRefundRequest(for:in:)`.
    static func beginRefundRequest(
        transactionID: UInt64,
        in scene: UIWindowScene,
        completion: @escaping (SystemUIRefundOutcome) -> Void
    ) {
        let completion = UncheckedSendable(completion)
        Task { @MainActor in
            do {
                switch try await Transaction.beginRefundRequest(for: transactionID, in: scene) {
                case .success: completion.value(.success)
                case .userCancelled: completion.value(.userCancelled)
                @unknown default: completion.value(.error)
                }
            } catch {
                completion.value(.error)
            }
        }
    }
}
