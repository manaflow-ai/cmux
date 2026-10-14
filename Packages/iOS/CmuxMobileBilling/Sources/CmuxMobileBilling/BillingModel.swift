import CMUXMobileCore
import Foundation
import Observation

/// Owns App Store billing for the app: account state, offers, purchase,
/// restore, and the long-lived transaction listener.
///
/// The server is the source of truth. Every verified transaction goes to
/// `POST /api/billing/apple/transactions` through
/// ``BillingTransactionDeliverer``, which finishes it only after a 2xx. A
/// transaction the server did not accept stays unfinished; StoreKit keeps it,
/// and ``retryUndeliveredTransactions()`` posts it again at launch, sign-in,
/// foreground, and each time the plans screen loads. A transaction the server
/// refused for good (``BillingFailure/isPermanentRejection``, for example
/// another account's subscription) is not re-posted automatically until the
/// account changes, and is never finished, so the right account can still
/// claim it.
///
/// Build one at the composition root, call ``start()`` once at launch, and
/// inject it into SwiftUI with `.environment(model)`.
///
/// ```swift
/// let model = BillingModel(api: api, store: LiveStoreKitClient(), analytics: emitter)
/// model.start()
/// ```
@MainActor
@Observable
public final class BillingModel {
    /// The account-token response state.
    public private(set) var account: BillingAccountState = .idle
    /// The plans on sale with their StoreKit prices, smallest plan first.
    public private(set) var offers: [BillingOffer] = []
    /// Why StoreKit products could not be loaded, when they could not.
    public private(set) var offersFailure: BillingFailure?
    /// The current purchase attempt.
    public private(set) var purchase: BillingPurchasePhase = .idle
    /// The current restore attempt.
    public private(set) var restore: BillingRestorePhase = .idle

    private let api: any BillingAPI
    private let store: any StoreKitClient
    private let deliverer: BillingTransactionDeliverer
    private let analytics: (any AnalyticsEmitting)?
    private var listenerTask: Task<Void, Never>?
    /// Bumped on sign-out so a load that started for the previous account
    /// cannot publish its result.
    private var accountGeneration = 0
    /// Transactions the server refused for good for the current account. They
    /// stay unfinished; automatic retries skip them until sign-out.
    private var rejectedTransactions: [UInt64: BillingFailure] = [:]

    /// Creates the model.
    /// - Parameters:
    ///   - api: The billing routes.
    ///   - store: The StoreKit seam.
    ///   - analytics: The product analytics emitter; nil sends nothing.
    public init(api: any BillingAPI, store: any StoreKitClient, analytics: (any AnalyticsEmitting)?) {
        self.api = api
        self.store = store
        self.deliverer = BillingTransactionDeliverer(api: api, store: store)
        self.analytics = analytics
    }

    /// Starts the `Transaction.updates` listener and retries unfinished
    /// transactions. Call once at app launch; later calls do nothing.
    public func start() {
        guard listenerTask == nil else { return }
        let updates = store.transactionUpdates()
        listenerTask = Task { [weak self] in
            for await update in updates {
                guard let self else { return }
                await self.handle(update)
            }
        }
        Task { await retryUndeliveredTransactions() }
    }

    /// Stops the transaction listener.
    public func stop() {
        listenerTask?.cancel()
        listenerTask = nil
    }

    /// Loads the account and its offers, after retrying any transaction the
    /// server has not accepted yet so the plan shown is current.
    public func refresh() async {
        await retryUndeliveredTransactions()
        await loadAccount()
    }

    /// Records that the plans screen appeared.
    /// - Parameter entryPoint: Where the screen was opened from.
    public func paywallViewed(entryPoint: BillingEntryPoint) {
        capture(.paywallViewed, ["entry_point": .string(entryPoint.rawValue)])
    }

    /// Buys an offer with the account's `appAccountToken`, sends the
    /// transaction to the server, and finishes it once the server accepts it.
    /// - Parameters:
    ///   - offer: The offer to buy.
    ///   - entryPoint: Where the plans screen was opened from.
    public func buy(_ offer: BillingOffer, entryPoint: BillingEntryPoint) async {
        guard !purchase.isPurchasing else { return }
        let properties: [String: AnalyticsValue] = [
            "entry_point": .string(entryPoint.rawValue),
            "product_id": .string(offer.product.id),
            "plan_id": .string(offer.planID.rawValue),
        ]
        capture(.purchaseStarted, properties)
        guard let account = account.account else {
            fail(.invalidResponse, properties: properties)
            return
        }
        guard account.eligible else {
            fail(.notEligible, properties: properties)
            return
        }
        purchase = .purchasing(productID: offer.product.id)
        let result: StorePurchaseResult
        do {
            result = try await store.purchase(productID: offer.product.id, appAccountToken: account.appAccountToken)
        } catch StoreKitClientError.userCancelled {
            purchase = .idle
            capture(.purchaseCancelled, properties)
            return
        } catch {
            fail(BillingFailure(error), properties: properties)
            return
        }
        switch result {
        case .userCancelled:
            purchase = .idle
            capture(.purchaseCancelled, properties)
        case .pending:
            purchase = .pending(productID: offer.product.id)
            capture(.purchasePending, properties)
        case .completed(.unverified):
            fail(.unverified, properties: properties)
        case .completed(.verified(let transaction)):
            switch await deliver(transaction) {
            case .accepted(let receipt):
                purchase = .completed(receipt.planID)
                await loadAccount()
            case .rejected(let failure):
                fail(failure, properties: properties)
            case .deferred:
                // Apple charged the user; only the server step is missing.
                // The transaction stays unfinished and is retried, and the
                // server also learns of it from App Store Server
                // Notifications, so this is not a failed purchase.
                purchase = .awaitingServer(productID: offer.product.id)
            }
        }
    }

    /// Restore Purchases: `AppStore.sync()`, then re-posts every current
    /// entitlement and unfinished transaction, then reloads the account.
    public func restorePurchases() async {
        guard restore != .restoring else { return }
        restore = .restoring
        capture(.restoreStarted, [:])
        do {
            try await store.syncWithAppStore()
        } catch StoreKitClientError.userCancelled {
            restore = .idle
            capture(.restoreCompleted, ["success": .bool(false), "reason": .string("cancelled")])
            return
        } catch {
            let failure = BillingFailure(error)
            restore = .failed(failure)
            capture(.restoreCompleted, ["success": .bool(false), "reason": .string(failure.analyticsReason)])
            return
        }
        var accepted = 0
        var lastFailure: BillingFailure?
        // Restore is an explicit request, so it posts even transactions the
        // server refused earlier in this session.
        for entitlement in await store.currentEntitlements() {
            guard case .verified(let transaction) = entitlement else { continue }
            switch await deliver(transaction) {
            case .accepted: accepted += 1
            case .deferred(let failure), .rejected(let failure): lastFailure = failure
            }
        }
        await retryUndeliveredTransactions()
        await loadAccount()
        if accepted == 0, let lastFailure {
            restore = .failed(lastFailure)
            capture(.restoreCompleted, [
                "success": .bool(false),
                "reason": .string(lastFailure.analyticsReason),
            ])
        } else {
            restore = .completed(acceptedCount: accepted)
            capture(.restoreCompleted, ["success": .bool(true), "restored_count": .int(accepted)])
        }
    }

    /// Posts every unfinished verified transaction to the server and finishes
    /// the ones it accepts. Unverified transactions are never posted, and
    /// transactions refused for good are skipped until the account changes.
    public func retryUndeliveredTransactions() async {
        for update in await store.unfinishedTransactions() {
            await handle(update)
        }
    }

    /// Clears the result banner of the last purchase or restore.
    public func dismissResult() {
        if !purchase.isPurchasing { purchase = .idle }
        if restore != .restoring { restore = .idle }
    }

    /// Forgets the signed-out account. Unfinished transactions stay with
    /// StoreKit and are delivered for whichever account signs in next, even
    /// ones the previous account was refused; the server rejects a token that
    /// belongs to another user.
    public func resetForSignOut() {
        accountGeneration += 1
        rejectedTransactions = [:]
        account = .idle
        offers = []
        offersFailure = nil
        purchase = .idle
        restore = .idle
    }

    /// Delivers one transaction from the listener or a retry.
    func handle(_ update: StoreTransactionVerification) async {
        guard case .verified(let transaction) = update, rejectedTransactions[transaction.id] == nil else { return }
        let receipt: BillingTransactionReceipt
        switch await deliver(transaction) {
        case .accepted(let accepted):
            receipt = accepted
        case .rejected(let failure):
            if purchase.isWaiting(for: transaction.productID) { purchase = .failed(failure) }
            return
        case .deferred:
            return
        }
        if purchase.isWaiting(for: transaction.productID) {
            purchase = .completed(receipt.planID)
        }
        if account.account != nil {
            await loadAccount()
        }
    }

    /// Posts one transaction and remembers a permanent refusal for this
    /// account, unless the account changed while the post ran.
    private func deliver(_ transaction: StoreTransaction) async -> BillingDeliveryOutcome {
        let generation = accountGeneration
        let outcome = await deliverer.deliver(transaction)
        switch outcome {
        case .rejected(let failure) where generation == accountGeneration:
            rejectedTransactions[transaction.id] = failure
        case .accepted:
            rejectedTransactions[transaction.id] = nil
        default:
            break
        }
        return outcome
    }

    private func loadAccount() async {
        let generation = accountGeneration
        if account.account == nil { account = .loading }
        let loaded: BillingAccount
        do {
            loaded = try await api.accountToken()
        } catch {
            guard generation == accountGeneration else { return }
            if account.account == nil { account = .failed(BillingFailure(error)) }
            return
        }
        guard generation == accountGeneration else { return }
        account = .loaded(loaded)
        await loadOffers(for: loaded, generation: generation)
    }

    private func loadOffers(for account: BillingAccount, generation: Int) async {
        guard account.eligible, !account.products.isEmpty else {
            offers = []
            offersFailure = nil
            return
        }
        let products: [StoreProduct]
        do {
            products = try await store.products(for: account.products.map(\.productID))
        } catch {
            guard generation == accountGeneration else { return }
            offersFailure = BillingFailure(error)
            return
        }
        guard generation == accountGeneration else { return }
        let byID = Dictionary(products.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        offers = account.products
            .compactMap { reference in byID[reference.productID].map { BillingOffer(planID: reference.planID, product: $0) } }
            .sorted { $0.planID < $1.planID }
        offersFailure = offers.isEmpty ? .productUnavailable : nil
    }

    private func fail(_ failure: BillingFailure, properties: [String: AnalyticsValue]) {
        purchase = .failed(failure)
        var properties = properties
        properties["reason"] = .string(failure.analyticsReason)
        capture(.purchaseFailed, properties)
    }

    private func capture(_ event: BillingAnalyticsEvent, _ properties: [String: AnalyticsValue]) {
        analytics?.capture(event.name, properties)
    }
}
