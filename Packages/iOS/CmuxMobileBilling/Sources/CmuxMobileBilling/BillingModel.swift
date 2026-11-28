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
    /// The product of the account's active App Store subscription on this
    /// Apple Account, from StoreKit's current entitlements; nil when unknown.
    /// It tells Pro Monthly from Pro Yearly, which the server's plan id
    /// cannot.
    public private(set) var currentAppleProductID: String?
    /// The latest transaction of that subscription, for the App Store refund
    /// request sheet; nil when unknown.
    public private(set) var currentAppleTransactionID: UInt64?
    /// The current purchase attempt.
    public private(set) var purchase: BillingPurchasePhase = .idle
    /// The current restore attempt.
    public private(set) var restore: BillingRestorePhase = .idle
    /// Whether the paywall may show a free trial. Trial text shows only in
    /// ``BillingTrialState/available(_:)``.
    public private(set) var trial: BillingTrialState = .none
    /// The products the server lists, with StoreKit prices, loaded for the
    /// staff Paywall Lab even when this account cannot buy.
    public private(set) var previewOffers: [BillingOffer] = []

    private let api: any BillingAPI
    private let store: any StoreKitClient
    private let deliverer: BillingTransactionDeliverer
    private let analytics: (any AnalyticsEmitting)?
    private let trialProver: (any BillingTrialDeviceProving)?
    /// The offer of the running purchase, for a success the listener
    /// reports later (the trial product is not among ``offers``).
    private var purchaseOffer: BillingOffer?
    private var listenerTask: Task<Void, Never>?
    /// Bumped on sign-out so a load that started for the previous account
    /// cannot publish its result.
    private var accountGeneration = 0
    /// Transactions the server refused for good for the current account. They
    /// stay unfinished; automatic retries skip them until sign-out.
    private var rejectedTransactions: [UInt64: BillingFailure] = [:]
    /// The last product-load outcome sent to analytics, so a reload with the
    /// same result (after a purchase, restore or renewal) is not counted again.
    private var lastProductsEvent: String?
    /// The paywall session of the running purchase, so a success reported
    /// later by the transaction listener (Ask to Buy) carries its variant.
    private var purchaseContext: BillingPaywallContext?
    /// The account load in flight, joined by ``loadIfNeeded()``.
    private var inFlightLoad: Task<Void, Never>?

    /// Creates the model.
    /// - Parameters:
    ///   - api: The billing routes.
    ///   - store: The StoreKit seam.
    ///   - analytics: The product analytics emitter; nil sends nothing.
    ///   - trialProver: Makes the App Attest and DeviceCheck proof a free
    ///     trial needs; nil offers no trial.
    public init(
        api: any BillingAPI,
        store: any StoreKitClient,
        analytics: (any AnalyticsEmitting)?,
        trialProver: (any BillingTrialDeviceProving)? = nil
    ) {
        self.api = api
        self.store = store
        self.deliverer = BillingTransactionDeliverer(api: api, store: store)
        self.analytics = analytics
        self.trialProver = trialProver
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

    /// Loads the account once: does nothing when it is loaded, and joins a
    /// load already running instead of starting a second one. Upgrade
    /// entry points call this, so several on one screen cost one request.
    public func loadIfNeeded() async {
        if account.account != nil { return }
        let generation = accountGeneration
        if let inFlightLoad {
            await inFlightLoad.value
            // A load joined across a sign-out published nothing; load again.
            if generation == accountGeneration || account.account != nil { return }
        }
        let load = Task { await self.refresh() }
        inFlightLoad = load
        await load.value
        if inFlightLoad == load { inFlightLoad = nil }
    }

    /// The paywall configuration to show: the server's, or
    /// ``BillingPaywallConfig/control`` when it sent none or an invalid one.
    public var paywallConfig: BillingPaywallConfig {
        account.account?.paywall ?? .control
    }

    /// Where ``paywallConfig`` came from.
    public var paywallConfigSource: BillingPaywallConfigSource {
        account.account?.paywall == nil ? .builtIn : .server
    }

    /// A paywall session for `entryPoint` over the current configuration.
    /// - Parameter entryPoint: Where the paywall opens from.
    public func paywallContext(entryPoint: BillingEntryPoint) -> BillingPaywallContext {
        BillingPaywallContext(entryPoint: entryPoint, config: paywallConfig, configSource: paywallConfigSource)
    }

    /// True when the app may offer an upgrade: a loaded account on the Free
    /// plan that may buy in the App Store. False for web subscribers, team
    /// billing, builds that sell nothing, and paid plans, so no upgrade
    /// entry point shows for them.
    public var canOfferUpgrade: Bool {
        guard let account = account.account else { return false }
        return account.eligible && account.currentPlan.planID == .free
    }

    /// True when the app may offer a bigger plan: a loaded account that may
    /// buy in the App Store and is not on the largest plan. Used where a
    /// plan limit stops an action (a locked machine size, a 402 refusal).
    public var canOfferPlanChange: Bool {
        guard let account = account.account else { return false }
        return account.eligible && account.currentPlan.planID != .max
    }

    /// A plan's compute facts: the server's, else the published built-in
    /// ones.
    public func planFacts(_ plan: BillingPlanID) -> BillingPlanFacts? {
        account.account?.planFacts[plan.rawValue] ?? BillingPlanFacts.builtIn[plan]
    }

    /// Records that the plans screen appeared.
    /// - Parameter entryPoint: Where the screen was opened from.
    public func paywallViewed(entryPoint: BillingEntryPoint) {
        capture(.paywallViewed, ["entry_point": .string(entryPoint.rawValue)])
    }

    /// Records that the paywall appeared with its experiment properties.
    /// - Parameter context: The paywall session.
    public func paywallViewed(context: BillingPaywallContext) {
        capture(.paywallViewed, context.analyticsProperties)
    }

    /// Records a tap on the paywall's purchase button.
    /// - Parameters:
    ///   - offer: The offer the button buys.
    ///   - context: The paywall session.
    public func paywallCTATapped(_ offer: BillingOffer, context: BillingPaywallContext) {
        var properties = context.analyticsProperties
        properties["plan_id"] = .string(offer.planID.rawValue)
        properties["billing_period"] = .string(offer.billingPeriod.rawValue)
        capture(.paywallCTATapped, properties)
    }

    /// Records that the paywall closed.
    /// - Parameters:
    ///   - context: The paywall session.
    ///   - secondsVisible: How long it was on screen.
    ///   - reachedPurchase: Whether the user started a purchase from it.
    public func paywallDismissed(context: BillingPaywallContext, secondsVisible: Double, reachedPurchase: Bool) {
        var properties = context.analyticsProperties
        properties["seconds_visible"] = .double((secondsVisible * 10).rounded() / 10)
        properties["reached_purchase"] = .bool(reachedPurchase)
        capture(.paywallDismissed, properties)
    }

    /// Records that an upgrade card or banner appeared.
    /// - Parameter entryPoint: Which entry point.
    public func upgradeEntryViewed(_ entryPoint: BillingEntryPoint) {
        capture(.upgradeEntryViewed, ["entry_point": .string(entryPoint.rawValue)])
    }

    /// Records that the paywall showed a free trial offer.
    /// - Parameters:
    ///   - grant: The trial shown.
    ///   - context: The paywall session.
    public func trialOfferShown(_ grant: BillingTrialGrant, context: BillingPaywallContext) {
        var properties = context.analyticsProperties
        properties["plan_id"] = .string(grant.planID.rawValue)
        properties["billing_period"] = .string(grant.billingOffer.billingPeriod.rawValue)
        capture(.trialOfferShown, properties)
    }

    /// Checks whether the paywall may show a free trial: the server must
    /// offer one, StoreKit must have a free-trial introductory offer on the
    /// trial product, the device must pass App Attest and DeviceCheck, and
    /// the server must grant it. Anything else leaves no trial to show.
    /// Runs once per account; later calls return at once.
    public func prepareTrial() async {
        switch trial {
        case .checking, .available: return
        // A network failure is retried the next time the paywall opens;
        // a refusal or an unsupported device is final for this account.
        case .unavailable(let reason) where !reason.hasSuffix("network"): return
        case .none, .unavailable: break
        }
        guard let account = account.account, let offer = account.trial, offer.offered,
              account.eligible, account.currentPlan.planID == .free
        else { return }
        let generation = accountGeneration
        trial = .checking
        let result = await checkTrial(offer, account: account)
        guard generation == accountGeneration else { return }
        trial = result
    }

    private func checkTrial(_ offer: BillingTrialOffer, account: BillingAccount) async -> BillingTrialState {
        // The trial lives only on its own product, so a refused account can
        // never get it from a normal product's introductory offer.
        guard let productID = offer.productID else {
            return .unavailable(reason: "no_product")
        }
        let product: StoreProduct
        do {
            guard let found = try await store.products(for: [productID]).first else {
                return .unavailable(reason: "no_product")
            }
            product = found
        } catch {
            return .unavailable(reason: "products_" + BillingFailure(error).analyticsReason)
        }
        guard let introductory = product.introductoryOffer, introductory.isFreeTrial else {
            return .unavailable(reason: "no_intro_offer")
        }
        guard let trialProver, await trialProver.isSupported else {
            return attestFailed("unsupported")
        }
        let appTransactionID = await store.appTransactionID()
        var verification: BillingTrialVerification?
        for attempt in 0..<2 {
            do {
                let challenge = try await api.trialChallenge()
                let proof = try await trialProver.proof(clientData: Data((challenge + productID).utf8))
                verification = try await api.verifyTrial(BillingTrialVerifyRequest(
                    challenge: challenge,
                    proof: proof,
                    productID: productID,
                    appTransactionID: appTransactionID
                ))
                break
            } catch BillingAPIError.attestKeyUnknown where attempt == 0 {
                await trialProver.resetKey()
            } catch let error as BillingTrialProofError {
                switch error {
                case .unsupported: return attestFailed("unsupported")
                case .attest: return attestFailed("attest")
                case .deviceCheck: return attestFailed("device_check")
                }
            } catch {
                return attestFailed("verify_" + BillingFailure(error).analyticsReason)
            }
        }
        guard let verification else { return attestFailed("attest_key_unknown") }
        guard verification.eligible else {
            return .unavailable(reason: verification.reason ?? "not_eligible")
        }
        // iOS 18.4 and later pass the signed eligibility to StoreKit. Earlier
        // systems cannot, so StoreKit decides by the Apple Account's own
        // eligibility, and the trial shows only when both agree.
        let jws = verification.introductoryOfferJWS
        let canSign: Bool
        if #available(iOS 18.4, macOS 15.4, *) { canSign = jws != nil } else { canSign = false }
        if !canSign {
            guard verification.legacyTrialAllowed, introductory.isEligibleOnDevice else {
                return .unavailable(reason: "legacy_not_allowed")
            }
        }
        return .available(BillingTrialGrant(
            planID: offer.planID,
            product: product,
            introductoryOfferJWS: canSign ? jws : nil,
            offer: introductory,
            limits: offer.limits
        ))
    }

    private func attestFailed(_ reason: String) -> BillingTrialState {
        capture(.trialAttestFailed, ["reason": .string(reason)])
        return .unavailable(reason: reason)
    }

    /// The staff Paywall Lab list: every live and retired variant.
    /// - Returns: The variants.
    /// - Throws: ``BillingAPIError``.
    public func paywallVariants() async throws -> [BillingPaywallVariant] {
        try await api.paywallVariants()
    }

    /// Loads ``previewOffers`` for the Paywall Lab: the account's offers when
    /// it may buy, else StoreKit prices for the products the server lists.
    public func loadPreviewOffers() async {
        guard let account = account.account else { return }
        if account.eligible, !offers.isEmpty {
            previewOffers = offers
            return
        }
        guard !account.products.isEmpty,
              let products = try? await store.products(for: account.products.map(\.productID))
        else { return }
        let byID = Dictionary(products.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        previewOffers = account.products
            .compactMap { reference in
                byID[reference.productID].map {
                    BillingOffer(planID: reference.planID, product: $0, billingPeriod: reference.billingPeriod)
                }
            }
            .sorted { ($0.planID, $0.billingPeriod) < ($1.planID, $1.billingPeriod) }
    }

    /// Loads the StoreKit product of the account's trial offer, for the
    /// Paywall Lab's trial preview. Nil when there is no offer or product.
    public func trialPreviewProduct() async -> StoreProduct? {
        guard let account = account.account else { return nil }
        let productID = account.trial?.productID ?? "\(Self.productPrefix(account)).pro.trial.monthly"
        return try? await store.products(for: [productID]).first
    }

    private static func productPrefix(_ account: BillingAccount) -> String {
        guard let id = account.products.first?.productID, let dot = id.range(of: ".", options: .backwards) else { return "" }
        let withoutPeriod = id[..<dot.lowerBound]
        guard let planDot = withoutPeriod.range(of: ".", options: .backwards) else { return "" }
        return String(withoutPeriod[..<planDot.lowerBound])
    }

    /// Buys an offer with the account's `appAccountToken`, sends the
    /// transaction to the server, and finishes it once the server accepts it.
    /// - Parameters:
    ///   - offer: The offer to buy.
    ///   - entryPoint: Where the plans screen was opened from.
    public func buy(_ offer: BillingOffer, entryPoint: BillingEntryPoint) async {
        await buy(offer, context: paywallContext(entryPoint: entryPoint))
    }

    /// The product of the last purchase the App Store charged in this
    /// session; kept when the result banner is dismissed.
    private var lastChargedProductID: String?

    /// Buys an offer from a paywall session; the purchase events carry the
    /// session's experiment properties.
    /// - Parameters:
    ///   - offer: The offer to buy.
    ///   - context: The paywall session.
    ///   - trial: The granted free trial, when `offer` is its product; its
    ///     signed eligibility goes to StoreKit.
    /// - Returns: True when the App Store charged for `offer` (the server
    ///   applied it or will), independent of the result banner's state.
    @discardableResult
    public func buy(_ offer: BillingOffer, context: BillingPaywallContext, trial: BillingTrialGrant? = nil) async -> Bool {
        lastChargedProductID = nil
        await performBuy(offer, context: context, trial: trial)
        return lastChargedProductID == offer.product.id
    }

    private func performBuy(_ offer: BillingOffer, context: BillingPaywallContext, trial: BillingTrialGrant?) async {
        let trial = trial?.productID == offer.product.id ? trial : nil
        guard !purchase.isPurchasing else { return }
        var properties = context.analyticsProperties
        properties["product_id"] = .string(offer.product.id)
        properties["plan_id"] = .string(offer.planID.rawValue)
        properties["billing_period"] = .string(offer.billingPeriod.rawValue)
        properties["trial"] = .bool(trial != nil)
        purchaseContext = context
        purchaseOffer = offer
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
            result = try await store.purchase(
                productID: offer.product.id,
                appAccountToken: account.appAccountToken,
                introductoryOfferJWS: trial?.introductoryOfferJWS
            )
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
                lastChargedProductID = offer.product.id
                capturePurchaseSucceeded(offer, transaction, delivery: "accepted")
                await loadAccount()
            case .rejected(let failure):
                fail(failure, properties: properties)
            case .deferred:
                // Apple charged the user; only the server step is missing.
                // The transaction stays unfinished and is retried, and the
                // server also learns of it from App Store Server
                // Notifications, so this is not a failed purchase.
                purchase = .awaitingServer(productID: offer.product.id)
                lastChargedProductID = offer.product.id
                capturePurchaseSucceeded(offer, transaction, delivery: "deferred")
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

    /// Records that the App Store refund request sheet opened.
    /// - Parameter productID: The subscription the refund is for.
    public func refundRequestOpened(productID: String) {
        capture(.refundRequestOpened, ["product_id": .string(productID)])
    }

    /// Records how the App Store refund request sheet ended.
    /// - Parameters:
    ///   - productID: The subscription the refund is for.
    ///   - result: `success`, `userCancelled`, or `error`.
    public func refundRequestFinished(productID: String, result: String) {
        capture(.refundRequestResult, ["product_id": .string(productID), "result": .string(result)])
    }

    /// Clears the result banner of the last purchase or restore.
    /// A purchase waiting for Ask to Buy approval or for the server keeps
    /// its phase, so its later success is still matched and reported.
    public func dismissResult() {
        switch purchase {
        case .completed, .failed: purchase = .idle
        case .idle, .purchasing, .pending, .awaitingServer: break
        }
        if restore != .restoring { restore = .idle }
    }

    /// Forgets the signed-out account. Unfinished transactions stay with
    /// StoreKit and are delivered for whichever account signs in next, even
    /// ones the previous account was refused; the server rejects a token that
    /// belongs to another user.
    public func resetForSignOut() {
        accountGeneration += 1
        rejectedTransactions = [:]
        lastProductsEvent = nil
        currentAppleProductID = nil
        currentAppleTransactionID = nil
        purchaseContext = nil
        purchaseOffer = nil
        inFlightLoad = nil
        trial = .none
        previewOffers = []
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
        if case .pending(let productID) = purchase, productID == transaction.productID,
           let offer = offers.first(where: { $0.product.id == productID })
            ?? purchaseOffer.flatMap({ $0.product.id == productID ? $0 : nil }) {
            // An approved Ask to Buy purchase: the App Store charged now.
            // An awaitingServer purchase already reported its success.
            capturePurchaseSucceeded(offer, transaction, delivery: "accepted")
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
        if loaded.trial?.offered != true || loaded.currentPlan.planID != .free {
            // The offer ended or the account subscribed: no trial to show.
            trial = .none
        }
        account = .loaded(loaded)
        await loadOffers(for: loaded, generation: generation)
        await loadCurrentAppleProduct(for: loaded, generation: generation)
    }

    private func loadOffers(for account: BillingAccount, generation: Int) async {
        guard account.eligible else {
            offers = []
            offersFailure = nil
            return
        }
        guard !account.products.isEmpty else {
            // Eligible, but the server sells nothing to this bundle: show
            // the unavailable state, not an endless spinner.
            offers = []
            offersFailure = .productUnavailable
            await captureProductsFailed(reason: "no_server_products", generation: generation)
            return
        }
        if offers.isEmpty {
            // Show the spinner again while a retry loads.
            offersFailure = nil
        }
        let products: [StoreProduct]
        do {
            products = try await store.products(for: account.products.map(\.productID))
        } catch {
            guard generation == accountGeneration else { return }
            let failure = BillingFailure(error)
            // Offers from an earlier load stay on screen; the failure shows
            // only when there is nothing to buy.
            offersFailure = failure
            await captureProductsFailed(reason: failure.analyticsReason, generation: generation)
            return
        }
        guard generation == accountGeneration else { return }
        let byID = Dictionary(products.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // The trial product is offered only through a granted trial.
        let trialProductID = account.trial?.productID
        offers = account.products
            .filter { $0.productID != trialProductID }
            .compactMap { reference in
                byID[reference.productID].map {
                    BillingOffer(planID: reference.planID, product: $0, billingPeriod: reference.billingPeriod)
                }
            }
            .sorted { ($0.planID, $0.billingPeriod) < ($1.planID, $1.billingPeriod) }
        if offers.isEmpty {
            offersFailure = .productUnavailable
            await captureProductsFailed(reason: BillingFailure.productUnavailable.analyticsReason, generation: generation)
        } else {
            offersFailure = nil
            let loadedIDs = offers.map(\.product.id)
            let periods = Set(offers.map(\.billingPeriod)).sorted().map(\.rawValue).joined(separator: ",")
            let signature = "loaded:" + loadedIDs.joined(separator: ",")
            guard signature != lastProductsEvent else { return }
            let storefront = await store.storefrontCountryCode()
            guard generation == accountGeneration, signature != lastProductsEvent else { return }
            lastProductsEvent = signature
            capture(.productsLoaded, [
                "product_ids": .string(loadedIDs.joined(separator: ",")),
                "storefront": .string(storefront ?? "unknown"),
                "count": .int(loadedIDs.count),
                "billing_period": .string(periods),
            ])
        }
    }

    private func loadCurrentAppleProduct(for account: BillingAccount, generation: Int) async {
        guard generation == accountGeneration else { return }
        guard account.currentPlan.source == .apple else {
            currentAppleProductID = nil
            currentAppleTransactionID = nil
            return
        }
        let sold = Set(account.products.filter { $0.planID == account.currentPlan.planID }.map(\.productID))
        var current: StoreTransaction?
        for entitlement in await store.currentEntitlements() {
            // Only this cmux account's subscription: the Apple Account may
            // also hold one bought for another cmux account.
            if case .verified(let transaction) = entitlement, sold.contains(transaction.productID),
               transaction.appAccountToken == account.appAccountToken {
                current = transaction
            }
        }
        guard generation == accountGeneration else { return }
        currentAppleProductID = current?.productID
        currentAppleTransactionID = current?.id
    }

    private func captureProductsFailed(reason: String, generation: Int) async {
        let signature = "failed:" + reason
        guard signature != lastProductsEvent else { return }
        let storefront = await store.storefrontCountryCode()
        guard generation == accountGeneration, signature != lastProductsEvent else { return }
        lastProductsEvent = signature
        capture(.productsFailed, [
            "reason": .string(reason),
            "storefront": .string(storefront ?? "unknown"),
        ])
    }

    private func capturePurchaseSucceeded(_ offer: BillingOffer, _ transaction: StoreTransaction, delivery: String) {
        var properties = purchaseContext?.analyticsProperties ?? [:]
        properties.merge([
            "product_id": .string(transaction.productID),
            "plan_id": .string(offer.planID.rawValue),
            "billing_period": .string(offer.billingPeriod.rawValue),
            "environment": .string(transaction.environment ?? "unknown"),
            "delivery": .string(delivery),
        ]) { _, new in new }
        if let price = offer.product.price {
            properties["price"] = .double(NSDecimalNumber(decimal: price).doubleValue)
        }
        if let currency = offer.product.currencyCode {
            properties["currency"] = .string(currency)
        }
        capture(.purchaseSucceeded, properties)
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
