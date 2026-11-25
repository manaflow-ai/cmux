import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxMobileBilling

@MainActor
struct BillingRig {
    let log = EffectLog()
    let api: FakeBillingAPI
    let store: FakeStoreKitClient
    let analytics = RecordingAnalytics()
    let model: BillingModel

    init(account: BillingAccount = BillingFixtures.account()) async {
        api = FakeBillingAPI(log: log, account: account)
        store = FakeStoreKitClient(log: log)
        await store.configure(products: [
            BillingFixtures.product(.max, price: "$299.99"),
            BillingFixtures.product(.pro, price: "$74.99"),
            BillingFixtures.product(.go, price: "$14.99"),
        ])
        model = BillingModel(api: api, store: store, analytics: analytics)
    }

    func loadedOffer(_ plan: BillingPlanID) async throws -> BillingOffer {
        await model.refresh()
        return try #require(model.offers.first { $0.planID == plan })
    }
}

@MainActor
@Suite struct BillingModelPurchaseTests {
    @Test func purchasePostsTransactionAndFinishesOnlyAfterServerAccepts() async throws {
        let rig = await BillingRig()
        let offer = try await rig.loadedOffer(.pro)
        await rig.store.configure(purchaseResult: .success(.completed(.verified(BillingFixtures.transaction(7)))))

        await rig.model.buy(offer, entryPoint: .settings)

        #expect(await rig.log.entries == [
            "purchase:dev.cmux.ios.pro.monthly",
            "submit:jws-7",
            "finish:7",
        ])
        #expect(rig.model.purchase == .completed(.pro))
        #expect(await rig.store.purchaseTokens == [BillingFixtures.token])
        #expect(rig.analytics.names == ["ios_products_loaded", "ios_purchase_started", "ios_purchase_succeeded"])
    }

    @Test func serverRejectionKeepsTransactionUnfinishedUntilRetrySucceeds() async throws {
        let rig = await BillingRig()
        let offer = try await rig.loadedOffer(.pro)
        let transaction = BillingFixtures.transaction(8)
        await rig.store.configure(
            purchaseResult: .success(.completed(.verified(transaction))),
            unfinished: [.verified(transaction)]
        )
        await rig.api.setSubmitErrors([.transport])

        await rig.model.buy(offer, entryPoint: .settings)

        #expect(rig.model.purchase == .awaitingServer(productID: offer.product.id))
        #expect(await rig.store.finished.isEmpty)
        #expect(!rig.analytics.names.contains("ios_purchase_failed"))

        await rig.model.retryUndeliveredTransactions()

        #expect(await rig.store.finished == [8])
        #expect(rig.model.purchase == .completed(.pro))
        #expect(await rig.log.entries == [
            "purchase:dev.cmux.ios.pro.monthly",
            "submit:jws-8",
            "submit:jws-8",
            "finish:8",
        ])
    }

    @Test func serverStatusRejectionIsNotFinished() async throws {
        let rig = await BillingRig()
        let offer = try await rig.loadedOffer(.max)
        await rig.store.configure(purchaseResult: .success(.completed(.verified(BillingFixtures.transaction(9, plan: .max)))))
        await rig.api.setSubmitErrors([.rejected(statusCode: 503)])

        await rig.model.buy(offer, entryPoint: .cloudUpgrade)

        #expect(await rig.store.finished.isEmpty)
        #expect(rig.model.purchase == .awaitingServer(productID: offer.product.id))
    }

    @Test func accountMismatchIsTerminalAndLeavesTransactionUnfinished() async throws {
        let rig = await BillingRig()
        let offer = try await rig.loadedOffer(.pro)
        let transaction = BillingFixtures.transaction(12)
        await rig.store.configure(
            purchaseResult: .success(.completed(.verified(transaction))),
            unfinished: [.verified(transaction)]
        )
        await rig.api.setSubmitErrors([.accountMismatch])

        await rig.model.buy(offer, entryPoint: .settings)

        #expect(rig.model.purchase == .failed(.accountMismatch))
        #expect(await rig.store.finished.isEmpty)
        let failed = try #require(rig.analytics.events.last)
        #expect(failed.0 == "ios_purchase_failed")
        #expect(failed.1["reason"] == .string("account_mismatch"))

        // Not re-posted automatically for this session.
        await rig.model.retryUndeliveredTransactions()
        #expect(await rig.api.submitted == ["jws-12"])
        #expect(await rig.store.finished.isEmpty)
    }

    @Test func permanentRejectionsAreTerminalAndNotRepostedAutomatically() async throws {
        for status in [400, 403, 404, 409, 422] {
            let rig = await BillingRig()
            let offer = try await rig.loadedOffer(.pro)
            let transaction = BillingFixtures.transaction(13)
            await rig.store.configure(
                purchaseResult: .success(.completed(.verified(transaction))),
                unfinished: [.verified(transaction)]
            )
            await rig.api.setSubmitErrors([.rejected(statusCode: status)])

            await rig.model.buy(offer, entryPoint: .settings)
            await rig.model.retryUndeliveredTransactions()

            #expect(rig.model.purchase == .failed(.server(statusCode: status)), "status \(status)")
            #expect(await rig.api.submitted == ["jws-13"], "status \(status)")
            #expect(await rig.store.finished.isEmpty, "status \(status)")
        }
    }

    @Test func transientFailuresKeepRetryingUntilAccepted() async throws {
        let rig = await BillingRig()
        let transaction = BillingFixtures.transaction(14)
        await rig.store.configure(unfinished: [.verified(transaction)])
        await rig.api.setSubmitErrors([.transport, .rejected(statusCode: 500), .rejected(statusCode: 401), .notSignedIn])

        for _ in 0..<5 {
            await rig.model.retryUndeliveredTransactions()
        }

        #expect(await rig.api.submitted.count == 5)
        #expect(await rig.store.finished == [14])
    }

    @Test func signingInToAnotherAccountRetriesARejectedTransaction() async throws {
        let rig = await BillingRig()
        let transaction = BillingFixtures.transaction(15)
        await rig.store.configure(unfinished: [.verified(transaction)])
        await rig.api.setSubmitErrors([.accountMismatch])
        await rig.model.retryUndeliveredTransactions()
        await rig.model.retryUndeliveredTransactions()
        #expect(await rig.api.submitted == ["jws-15"])

        rig.model.resetForSignOut()
        await rig.model.retryUndeliveredTransactions()

        #expect(await rig.api.submitted == ["jws-15", "jws-15"])
        #expect(await rig.store.finished == [15])
    }

    @Test func awaitingPurchaseFailsWhenItsRetryIsRejected() async throws {
        let rig = await BillingRig()
        let offer = try await rig.loadedOffer(.pro)
        let transaction = BillingFixtures.transaction(16)
        await rig.store.configure(
            purchaseResult: .success(.completed(.verified(transaction))),
            unfinished: [.verified(transaction)]
        )
        await rig.api.setSubmitErrors([.transport, .accountMismatch])

        await rig.model.buy(offer, entryPoint: .settings)
        #expect(rig.model.purchase == .awaitingServer(productID: offer.product.id))
        await rig.model.retryUndeliveredTransactions()

        #expect(rig.model.purchase == .failed(.accountMismatch))
        #expect(await rig.store.finished.isEmpty)
    }

    @Test func userCancelledReturnsToIdleWithoutPosting() async throws {
        let rig = await BillingRig()
        let offer = try await rig.loadedOffer(.go)
        await rig.store.configure(purchaseResult: .success(.userCancelled))

        await rig.model.buy(offer, entryPoint: .settings)

        #expect(rig.model.purchase == .idle)
        #expect(await rig.api.submitted.isEmpty)
        #expect(rig.analytics.names == ["ios_products_loaded", "ios_purchase_started", "ios_purchase_cancelled"])
    }

    @Test func storeKitCancellationErrorCountsAsCancel() async throws {
        let rig = await BillingRig()
        let offer = try await rig.loadedOffer(.go)
        await rig.store.configure(purchaseResult: .failure(.userCancelled))

        await rig.model.buy(offer, entryPoint: .settings)

        #expect(rig.model.purchase == .idle)
        #expect(rig.analytics.names.last == "ios_purchase_cancelled")
    }

    @Test func unverifiedPurchaseIsNeverPostedOrFinished() async throws {
        let rig = await BillingRig()
        let offer = try await rig.loadedOffer(.pro)
        await rig.store.configure(purchaseResult: .success(.completed(.unverified(transactionID: 3, productID: offer.id))))

        await rig.model.buy(offer, entryPoint: .settings)

        #expect(rig.model.purchase == .failed(.unverified))
        #expect(await rig.api.submitted.isEmpty)
        #expect(await rig.store.finished.isEmpty)
        let failed = try #require(rig.analytics.events.last)
        #expect(failed.0 == "ios_purchase_failed")
        #expect(failed.1["reason"] == .string("unverified"))
    }

    @Test func networkFailureIsReportedAsFailed() async throws {
        let rig = await BillingRig()
        let offer = try await rig.loadedOffer(.pro)
        await rig.store.configure(purchaseResult: .failure(.network))

        await rig.model.buy(offer, entryPoint: .settings)

        #expect(rig.model.purchase == .failed(.network))
        #expect(rig.analytics.events.last?.1["reason"] == .string("network"))
    }

    @Test func pendingPurchaseCompletesWhenListenerDeliversApproval() async throws {
        let rig = await BillingRig()
        let offer = try await rig.loadedOffer(.pro)
        await rig.store.configure(purchaseResult: .success(.pending))
        rig.model.start()

        await rig.model.buy(offer, entryPoint: .settings)
        #expect(rig.model.purchase == .pending(productID: offer.id))
        #expect(rig.analytics.names.contains("ios_purchase_pending"))

        rig.store.emitUpdate(.verified(BillingFixtures.transaction(11)))
        await rig.store.waitUntilFinished(11)
        await settle { rig.model.purchase == .completed(.pro) }

        #expect(rig.model.purchase == .completed(.pro))
        #expect(await rig.log.entries.suffix(2) == ["submit:jws-11", "finish:11"])
        rig.model.stop()
    }

    /// Ask to Buy approval comes minutes or hours later, after the person
    /// left the plans screen (whose `onDisappear` dismisses the banner). The
    /// approval must still complete the purchase and report it.
    @Test func pendingPurchaseApprovedAfterBannerDismissedStillCompletes() async throws {
        let rig = await BillingRig()
        let offer = try await rig.loadedOffer(.pro)
        await rig.store.configure(purchaseResult: .success(.pending))
        rig.model.start()

        await rig.model.buy(offer, entryPoint: .settings)
        #expect(rig.model.purchase == .pending(productID: offer.id))
        rig.model.dismissResult()
        #expect(rig.model.purchase == .idle)

        rig.store.emitUpdate(.verified(BillingFixtures.transaction(12)))
        await rig.store.waitUntilFinished(12)
        await settle { rig.model.purchase == .completed(.pro) }

        #expect(rig.model.purchase == .completed(.pro))
        #expect(rig.analytics.names.filter { $0 == "ios_purchase_succeeded" }.count == 1)
        rig.model.stop()
    }

    /// A refund of the product a purchase still waits for (an Ask to Buy
    /// never answered, say) must not show as that purchase completing.
    @Test func refundOfWaitingProductDoesNotCompleteThePurchase() async throws {
        let rig = await BillingRig()
        let offer = try await rig.loadedOffer(.pro)
        await rig.store.configure(purchaseResult: .success(.pending))
        rig.model.start()
        await rig.model.buy(offer, entryPoint: .settings)
        await rig.api.setReceipt(BillingTransactionReceipt(planID: .free, status: "revoked", expiresAt: nil))
        let loadsBefore = await rig.api.accountLoads

        rig.store.emitUpdate(.verified(BillingFixtures.transaction(21)))
        await rig.store.waitUntilFinished(21)
        // handle() reloads the account after it decided; wait for that.
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while await rig.api.accountLoads == loadsBefore, ContinuousClock.now < deadline {
            await Task.yield()
        }
        #expect(await rig.api.accountLoads > loadsBefore)

        #expect(rig.model.purchase == .pending(productID: offer.id))
        #expect(!rig.analytics.names.contains("ios_purchase_succeeded"))
        rig.model.stop()
    }

    /// Starting another purchase while one waits for approval must not forget
    /// the first: its approval still completes and is reported.
    @Test func secondPurchaseKeepsTheFirstPendingOne() async throws {
        let rig = await BillingRig()
        let pro = try await rig.loadedOffer(.pro)
        let max = try #require(rig.model.offers.first { $0.planID == .max })
        await rig.store.configure(purchaseResult: .success(.pending))
        rig.model.start()
        await rig.model.buy(pro, entryPoint: .settings)
        await rig.store.configure(purchaseResult: .success(.userCancelled))
        await rig.model.buy(max, entryPoint: .settings)
        #expect(rig.model.purchase == .idle)

        rig.store.emitUpdate(.verified(BillingFixtures.transaction(22)))
        await rig.store.waitUntilFinished(22)
        await settle { rig.model.purchase == .completed(.pro) }

        #expect(rig.model.purchase == .completed(.pro))
        #expect(rig.analytics.names.filter { $0 == "ios_purchase_succeeded" }.count == 1)
        rig.model.stop()
    }

    /// Restore delivers the transaction an awaiting-server purchase waited
    /// for; the purchase completes there, and a later re-delivery does not
    /// complete it again.
    @Test func restoreCompletesAnAwaitingServerPurchase() async throws {
        let rig = await BillingRig()
        let offer = try await rig.loadedOffer(.pro)
        let transaction = BillingFixtures.transaction(23)
        await rig.store.configure(purchaseResult: .success(.completed(.verified(transaction))))
        await rig.api.setSubmitErrors([.transport])
        await rig.model.buy(offer, entryPoint: .settings)
        #expect(rig.model.purchase == .awaitingServer(productID: offer.id))

        await rig.store.configure(entitlements: [.verified(transaction)])
        await rig.model.restorePurchases()

        #expect(rig.model.purchase == .completed(.pro))
        rig.model.dismissResult()
        await rig.model.handle(.verified(transaction))
        #expect(rig.model.purchase == .idle, "nothing waits any more")
    }

    @Test func ineligibleAccountLoadsNoOffersAndCannotBuy() async throws {
        let rig = await BillingRig(account: BillingFixtures.account(
            eligible: false,
            reason: .stripeSubscriptionActive,
            plan: .pro,
            source: .stripe
        ))
        await rig.model.refresh()

        #expect(rig.model.offers.isEmpty)
        #expect(rig.model.account.account?.reason == .stripeSubscriptionActive)

        let offer = BillingOffer(planID: .max, product: BillingFixtures.product(.max, price: "$299.99"))
        await rig.model.buy(offer, entryPoint: .settings)
        #expect(rig.model.purchase == .failed(.notEligible))
        #expect(await rig.store.purchaseTokens.isEmpty)
    }

    @Test func offersFollowServerProductsInPlanOrder() async throws {
        let rig = await BillingRig(account: BillingFixtures.account(products: [.max, .pro]))
        await rig.model.refresh()

        #expect(rig.model.offers.map(\.planID) == [.pro, .max])
        #expect(rig.model.offers.map(\.product.displayPrice) == ["$74.99", "$299.99"])
    }

    @Test func missingStoreProductsReportUnavailable() async throws {
        let rig = await BillingRig()
        await rig.store.configure(products: [])
        await rig.model.refresh()

        #expect(rig.model.offers.isEmpty)
        #expect(rig.model.offersFailure == .productUnavailable)
    }

    @Test func signOutClearsAccountState() async throws {
        let rig = await BillingRig()
        await rig.model.refresh()
        rig.model.resetForSignOut()

        #expect(rig.model.account == .idle)
        #expect(rig.model.offers.isEmpty)
    }
}

@MainActor
@Suite struct BillingModelRestoreTests {
    @Test func restoreSyncsThenRepostsEntitlements() async throws {
        let rig = await BillingRig()
        await rig.model.refresh()
        await rig.store.configure(entitlements: [
            .verified(BillingFixtures.transaction(21)),
            .unverified(transactionID: 22, productID: "x"),
        ])

        await rig.model.restorePurchases()

        #expect(await rig.store.syncCount == 1)
        #expect(await rig.api.submitted == ["jws-21"])
        #expect(rig.model.restore == .completed(acceptedCount: 1))
        #expect(rig.analytics.names == ["ios_products_loaded", "ios_restore_started", "ios_restore_completed"])
        #expect(rig.analytics.events.last?.1["restored_count"] == .int(1))
    }

    @Test func restoreRepostsARejectedTransactionAndReportsTheMismatch() async throws {
        let rig = await BillingRig()
        let transaction = BillingFixtures.transaction(32)
        await rig.store.configure(unfinished: [.verified(transaction)], entitlements: [.verified(transaction)])
        await rig.api.setSubmitErrors([.accountMismatch, .accountMismatch])
        await rig.model.retryUndeliveredTransactions()

        await rig.model.restorePurchases()

        // Restore is an explicit request, so it posts again; the automatic
        // retry inside it does not.
        #expect(await rig.api.submitted == ["jws-32", "jws-32"])
        #expect(rig.model.restore == .failed(.accountMismatch))
        #expect(await rig.store.finished.isEmpty)
    }

    /// The plans screen shows the restore result before the purchase result, so
    /// a finished restore must not outlive a later purchase: after a failed
    /// Restore, a successful upgrade still said "The App Store couldn't
    /// complete the request" (Sandbox run on a Mac, 2026-11-17).
    @Test func aPurchaseReplacesAnEarlierRestoreResult() async throws {
        let rig = await BillingRig()
        let offer = try await rig.loadedOffer(.pro)
        await rig.store.configure(syncError: .system)
        await rig.model.restorePurchases()
        #expect(rig.model.restore == .failed(BillingFailure(StoreKitClientError.system)))
        await rig.store.configure(purchaseResult: .success(.completed(.verified(BillingFixtures.transaction(41)))))

        await rig.model.buy(offer, entryPoint: .settings)

        #expect(rig.model.purchase == .completed(.pro))
        #expect(rig.model.restore == .idle)
    }

    @Test func restoreCancelledAtSignInReturnsToIdle() async throws {
        let rig = await BillingRig()
        await rig.store.configure(syncError: .userCancelled)

        await rig.model.restorePurchases()

        #expect(rig.model.restore == .idle)
        #expect(await rig.api.submitted.isEmpty)
    }

    @Test func restoreReportsServerFailure() async throws {
        let rig = await BillingRig()
        await rig.store.configure(entitlements: [.verified(BillingFixtures.transaction(31))])
        await rig.api.setSubmitErrors([.transport])

        await rig.model.restorePurchases()

        #expect(rig.model.restore == .failed(.network))
        #expect(await rig.store.finished.isEmpty)
    }
}

@MainActor
@Suite struct BillingListenerTests {
    @Test func renewalFromListenerIsPostedThenFinished() async throws {
        let rig = await BillingRig()
        rig.model.start()

        rig.store.emitUpdate(.verified(BillingFixtures.transaction(41)))
        await rig.store.waitUntilFinished(41)

        #expect(await rig.log.entries == ["submit:jws-41", "finish:41"])
        rig.model.stop()
    }

    @Test func unverifiedUpdateIsIgnored() async throws {
        let rig = await BillingRig()
        await rig.store.configure(unfinished: [.unverified(transactionID: 51, productID: "x")])

        await rig.model.retryUndeliveredTransactions()

        #expect(await rig.api.submitted.isEmpty)
        #expect(await rig.store.finished.isEmpty)
    }

    @Test func concurrentDeliveriesOfOneTransactionPostOnce() async throws {
        let log = EffectLog()
        let api = FakeBillingAPI(log: log, account: BillingFixtures.account())
        let store = FakeStoreKitClient(log: log)
        let deliverer = BillingTransactionDeliverer(api: api, store: store)
        let transaction = BillingFixtures.transaction(61)

        async let first = deliverer.deliver(transaction)
        async let second = deliverer.deliver(transaction)
        let outcomes = await [first, second]

        #expect(outcomes.allSatisfy { if case .accepted = $0 { true } else { false } })
        #expect(await store.finished == [61])
    }

    /// StoreKit re-delivers a changed copy of a transaction under the same id
    /// (an upgrade marks the old Pro transaction upgraded). Arriving while the
    /// older copy posts, it is posted after that post, not dropped into it.
    @Test func changedCopyArrivingDuringAPostIsPostedAfterIt() async throws {
        let log = EffectLog()
        let api = FakeBillingAPI(log: log, account: BillingFixtures.account())
        let store = FakeStoreKitClient(log: log)
        let deliverer = BillingTransactionDeliverer(api: api, store: store)
        let original = BillingFixtures.transaction(71)
        let upgraded = StoreTransaction(
            id: original.id,
            productID: original.productID,
            jwsRepresentation: "jws-71-upgraded",
            appAccountToken: original.appAccountToken
        )
        await api.holdSubmissions()

        // A failed wait releases the held post first, so a broken deliverer
        // fails the test instead of hanging it on the unreleased post.
        async let first = deliverer.deliver(original)
        try await until { await api.heldCount == 1 } onTimeout: { await api.releaseSubmissions() }
        async let second = deliverer.deliver(upgraded)
        try await until { await deliverer.changedCopiesWaiting == 1 } onTimeout: { await api.releaseSubmissions() }
        #expect(await api.submitted == ["jws-71"], "the changed copy waits for the older post")
        await api.releaseSubmissions()
        let outcomes = await [first, second]

        #expect(outcomes.allSatisfy { if case .accepted = $0 { true } else { false } })
        #expect(await log.entries == ["submit:jws-71", "finish:71", "submit:jws-71-upgraded", "finish:71"])
    }

    /// Identical copies still share one post while a changed copy waits.
    @Test func identicalCopiesShareThePostAChangedCopyWaitsFor() async throws {
        let log = EffectLog()
        let api = FakeBillingAPI(log: log, account: BillingFixtures.account())
        let store = FakeStoreKitClient(log: log)
        let deliverer = BillingTransactionDeliverer(api: api, store: store)
        let original = BillingFixtures.transaction(72)
        let refunded = StoreTransaction(
            id: original.id,
            productID: original.productID,
            jwsRepresentation: "jws-72-refunded",
            appAccountToken: original.appAccountToken
        )
        await api.holdSubmissions()

        async let first = deliverer.deliver(original)
        try await until { await api.heldCount == 1 } onTimeout: { await api.releaseSubmissions() }
        async let changedA = deliverer.deliver(refunded)
        async let changedB = deliverer.deliver(refunded)
        try await until { await deliverer.changedCopiesWaiting == 2 } onTimeout: { await api.releaseSubmissions() }
        await api.releaseSubmissions()
        _ = await [first, changedA, changedB]

        #expect(await api.submitted == ["jws-72", "jws-72-refunded"])
    }
}

/// Re-checks an actor-isolated condition between yields until it holds; a
/// generous deadline only bounds a broken deliverer, it is not a delay.
/// `onTimeout` runs before the throw, so a test can release work its pending
/// `async let`s wait on (scope exit awaits them).
private func until(
    timeout: Duration = .seconds(10),
    _ condition: @Sendable () async -> Bool,
    onTimeout: @Sendable () async -> Void = {}
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while await !condition() {
        guard clock.now < deadline else {
            Issue.record("condition did not hold within \(timeout)")
            await onTimeout()
            throw CancellationError()
        }
        await Task.yield()
    }
}

/// Polls on the main actor until `condition` holds or a generous deadline
/// passes. The deadline, not an iteration count, bounds the wait, so a loaded
/// runner only slows a passing test while a broken model still fails.
@MainActor
func settle(timeout: Duration = .seconds(10), _ condition: @MainActor () -> Bool) async {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !condition(), clock.now < deadline {
        await Task.yield()
    }
}
