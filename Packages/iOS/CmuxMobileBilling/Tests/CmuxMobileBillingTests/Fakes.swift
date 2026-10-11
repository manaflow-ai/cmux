import CMUXMobileCore
import Foundation
@testable import CmuxMobileBilling

/// Ordered record of side effects across the fake store and API, so tests can
/// assert that a transaction is posted before it is finished.
actor EffectLog {
    private(set) var entries: [String] = []

    func append(_ entry: String) {
        entries.append(entry)
    }
}

actor FakeBillingAPI: BillingAPI {
    let log: EffectLog
    var account: BillingAccount
    var accountError: BillingAPIError?
    /// Errors returned by successive submissions; empty means accept.
    var submitErrors: [BillingAPIError] = []
    var receiptPlan: BillingPlanID = .pro
    private(set) var submitted: [String] = []
    private(set) var accountLoads = 0

    init(log: EffectLog, account: BillingAccount) {
        self.log = log
        self.account = account
    }

    func setSubmitErrors(_ errors: [BillingAPIError]) {
        submitErrors = errors
    }

    func setAccount(_ account: BillingAccount) {
        self.account = account
    }

    func accountToken() async throws -> BillingAccount {
        accountLoads += 1
        if let accountError { throw accountError }
        return account
    }

    func submitTransaction(signedTransactionInfo: String) async throws -> BillingTransactionReceipt {
        submitted.append(signedTransactionInfo)
        await log.append("submit:\(signedTransactionInfo)")
        if !submitErrors.isEmpty {
            throw submitErrors.removeFirst()
        }
        return BillingTransactionReceipt(planID: receiptPlan, status: "active", expiresAt: nil)
    }
}

actor FakeStoreKitClient: StoreKitClient {
    let log: EffectLog
    var products: [StoreProduct] = []
    var purchaseResult: Result<StorePurchaseResult, StoreKitClientError> = .success(.userCancelled)
    var syncError: StoreKitClientError?
    var unfinished: [StoreTransactionVerification] = []
    var entitlements: [StoreTransactionVerification] = []
    private(set) var purchaseTokens: [UUID] = []
    private(set) var finished: [UInt64] = []
    private(set) var syncCount = 0
    private let updates: AsyncStream<StoreTransactionVerification>
    private let updatesContinuation: AsyncStream<StoreTransactionVerification>.Continuation
    private let finishedStream: AsyncStream<UInt64>
    private let finishedContinuation: AsyncStream<UInt64>.Continuation

    init(log: EffectLog) {
        self.log = log
        (updates, updatesContinuation) = AsyncStream.makeStream()
        (finishedStream, finishedContinuation) = AsyncStream.makeStream()
    }

    func configure(
        products: [StoreProduct]? = nil,
        purchaseResult: Result<StorePurchaseResult, StoreKitClientError>? = nil,
        syncError: StoreKitClientError? = nil,
        unfinished: [StoreTransactionVerification]? = nil,
        entitlements: [StoreTransactionVerification]? = nil
    ) {
        if let products { self.products = products }
        if let purchaseResult { self.purchaseResult = purchaseResult }
        self.syncError = syncError
        if let unfinished { self.unfinished = unfinished }
        if let entitlements { self.entitlements = entitlements }
    }

    /// Emits a transaction on `Transaction.updates`.
    nonisolated func emitUpdate(_ update: StoreTransactionVerification) {
        updatesContinuation.yield(update)
    }

    /// Waits until the given transaction is finished.
    func waitUntilFinished(_ id: UInt64) async {
        if finished.contains(id) { return }
        for await finishedID in finishedStream where finishedID == id {
            return
        }
    }

    func products(for ids: [String]) async throws -> [StoreProduct] {
        products.filter { ids.contains($0.id) }
    }

    func purchase(productID: String, appAccountToken: UUID) async throws -> StorePurchaseResult {
        purchaseTokens.append(appAccountToken)
        await log.append("purchase:\(productID)")
        return try purchaseResult.get()
    }

    nonisolated func transactionUpdates() -> AsyncStream<StoreTransactionVerification> {
        updates
    }

    func unfinishedTransactions() async -> [StoreTransactionVerification] {
        unfinished
    }

    func currentEntitlements() async -> [StoreTransactionVerification] {
        entitlements
    }

    func syncWithAppStore() async throws {
        syncCount += 1
        if let syncError { throw syncError }
    }

    func finish(transactionID: UInt64) async {
        // Record every effect before publishing completion, so a waiter that
        // returns on `finished` or the stream sees the log entry too.
        await log.append("finish:\(transactionID)")
        finished.append(transactionID)
        unfinished.removeAll { verification in
            if case .verified(let transaction) = verification { return transaction.id == transactionID }
            return false
        }
        finishedContinuation.yield(transactionID)
    }
}

final class RecordingAnalytics: AnalyticsEmitting, @unchecked Sendable {
    private let lock = NSLock()
    private var captured: [(String, [String: AnalyticsValue])] = []

    var events: [(String, [String: AnalyticsValue])] {
        lock.withLock { captured }
    }

    var names: [String] { events.map(\.0) }

    func capture(_ event: String, _ properties: [String: AnalyticsValue]) {
        lock.withLock { captured.append((event, properties)) }
    }

    func identify(userId: String?, alias: String?, properties: [String: AnalyticsValue]) {}
    func setSuperProperties(_ properties: [String: AnalyticsValue]) {}
    func flush() async {}
}

/// Shared fixtures.
struct BillingFixtures {
    static let token = UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!
    static let bundle = "dev.cmux.ios"

    static func reference(_ plan: BillingPlanID) -> BillingProductReference {
        BillingProductReference(productID: "\(bundle).\(plan.rawValue).monthly", planID: plan)
    }

    static func product(_ plan: BillingPlanID, price: String) -> StoreProduct {
        StoreProduct(
            id: "\(bundle).\(plan.rawValue).monthly",
            displayName: plan.rawValue,
            productDescription: "",
            displayPrice: price,
            periodUnitName: "month"
        )
    }

    static func account(
        eligible: Bool = true,
        reason: BillingIneligibilityReason? = nil,
        plan: BillingPlanID = .free,
        source: BillingPlanSource = .none,
        products: [BillingPlanID] = [.go, .pro, .max]
    ) -> BillingAccount {
        BillingAccount(
            appAccountToken: token,
            eligible: eligible,
            reason: reason,
            currentPlan: BillingCurrentPlan(planID: plan, source: source),
            products: eligible ? products.map(reference(_:)) : []
        )
    }

    static func transaction(_ id: UInt64, plan: BillingPlanID = .pro) -> StoreTransaction {
        StoreTransaction(
            id: id,
            productID: "\(bundle).\(plan.rawValue).monthly",
            jwsRepresentation: "jws-\(id)",
            appAccountToken: token
        )
    }
}
