import CmuxMobileBilling
import Foundation
import StoreKit
import StoreKitTest
import XCTest

/// The App Store subscription lifecycle against StoreKit Testing: the real
/// ``LiveStoreKitClient`` and ``BillingModel`` over an `SKTestSession` of
/// `CmuxBilling.storekit`, with the cmux server replaced by
/// ``FakeCmuxBillingServer`` (the real one rejects Xcode-signed transactions).
///
/// Each test asserts what the app posts (decoded from the JWS), what it
/// finishes, and the plan state the plans screen shows, and attaches that
/// screen in light and dark.
///
/// What StoreKit Testing does that these tests pin down:
/// - A state change of a subscription (auto-renew off, expiry, a failed
///   renewal, a refund, an upgrade) re-delivers the affected transaction on
///   `Transaction.updates`, so the app posts it again; only renewals and
///   resolved purchases create new transactions.
/// - storekitd applies a session change asynchronously: entitlements and
///   renewal info catch up a moment later, so reads of them wait
///   (``StoreKitRig/eventually(_:timeout:file:line:_:)``).
///
/// Refund reversal has no test: SKTestSession offers
/// `refundTransaction(identifier:)` and nothing that undoes it. A reversal
/// reaches the server as an App Store Server Notification
/// (`REFUND_REVERSED`); the app never sees it.
@MainActor
final class BillingStoreKitTests: XCTestCase {
    private var rig: StoreKitRig!

    override func setUp() async throws {
        rig = try StoreKitRig()
        try await rig.start()
    }

    override func tearDown() async throws {
        try await rig?.stop()
        rig = nil
    }

    // MARK: - Purchase

    /// Buy Pro: the purchase JWS is posted, finished after the server
    /// accepts, and the plan, product and refund transaction id are set.
    func testBuyProPostsFinishesAndShowsPro() async throws {
        await PlansSnapshot.attach(rig.model, name: "01-free-before-purchase", to: self)
        let transactionID = try await buy(CmuxProduct.proMonthly)

        XCTAssertEqual(rig.model.purchase, .completed(.pro))
        // One purchased transaction. It may be posted more than once (the
        // purchase call, then the Transaction.updates or unfinished re-delivery;
        // the server route is idempotent), and storekitd can still deliver a
        // renewal left from an earlier test, so count distinct PURCHASE ids.
        let purchases = rig.server.posts.filter { $0.payload.transactionReason == "PURCHASE" }
        XCTAssertEqual(Set(purchases.map(\.payload.transactionID)), [transactionID])
        let posted = try XCTUnwrap(purchases.first?.payload)
        XCTAssertEqual(posted.productId, CmuxProduct.proMonthly)
        XCTAssertEqual(posted.environment, "Xcode")
        XCTAssertEqual(posted.appAccountToken?.lowercased(), rig.server.appAccountToken.uuidString.lowercased())
        XCTAssertNil(posted.revocationDate)
        XCTAssertGreaterThan(try XCTUnwrap(posted.expires), Date())
        // A re-delivery of the same transaction may still be in flight; it
        // is finished as soon as its post is accepted.
        try await rig.eventually("the purchase finished") { await !self.rig.unfinishedIDs().contains(transactionID) }
        XCTAssertEqual(rig.model.account.account?.currentPlan, BillingCurrentPlan(planID: .pro, source: .apple))
        XCTAssertEqual(rig.model.currentAppleProductID, CmuxProduct.proMonthly)
        XCTAssertEqual(rig.model.currentAppleTransactionID, transactionID)
        await PlansSnapshot.attach(rig.model, name: "02-pro-purchased", to: self)
    }

    /// Upgrade Pro Monthly to Max Monthly: the Max transaction is posted and
    /// granted at once, StoreKit marks the Pro transaction upgraded, and the
    /// plans screen shows Max as current.
    ///
    /// StoreKit Testing usually re-delivers the upgraded Pro transaction on
    /// `Transaction.updates` too, but not always: in about 2 of 10 runs, on a
    /// Mac mini and on a 6 vCPU Blacksmith runner alike (runs 45320509297 and
    /// 45320534930), no upgraded copy ever reached the app. The plan does not
    /// depend on it (the server grants the newer Max transaction of the same
    /// subscription, and hears of the upgrade from Apple), so a re-delivery is
    /// checked only when it arrives: it is posted marked upgraded.
    /// BillingTransactionDeliverer's unit tests pin that such a copy is never
    /// dropped by an older post of the same id.
    func testUpgradeProToMax() async throws {
        let proID = try await buy(CmuxProduct.proMonthly)
        let maxID = try await buy(CmuxProduct.maxMonthly)
        rig.dump("after upgrade to Max")

        XCTAssertNotEqual(proID, maxID)
        XCTAssertEqual(rig.model.purchase, .completed(.max))
        let maxPost = try XCTUnwrap(rig.server.posts.first { $0.payload.transactionID == maxID }?.payload)
        let proPost = try XCTUnwrap(rig.server.purchasePosts.first { $0.payload.transactionID == proID }?.payload)
        XCTAssertEqual(maxPost.originalTransactionID, proPost.originalTransactionID,
                       "one subscription group: the upgrade keeps the original transaction")
        try await rig.eventually("StoreKit marks the Pro transaction upgraded") {
            for await verification in Transaction.all {
                if case .verified(let transaction) = verification, transaction.id == proID, transaction.isUpgraded {
                    return true
                }
            }
            return false
        }
        try await rig.waitUntil("the account shows Max with the Max product current") {
            self.rig.model.account.account?.currentPlan.planID == .max
                && self.rig.model.currentAppleProductID == CmuxProduct.maxMonthly
        }
        XCTAssertEqual(rig.model.currentAppleTransactionID, maxID)
        try await rig.eventually("only Max entitled") { await self.rig.entitledProductIDs() == [CmuxProduct.maxMonthly] }
        let proPosts = rig.server.posts.filter { $0.payload.transactionID == proID }
        let upgradedPosts = proPosts.filter { $0.payload.isUpgraded == true }
        print("[storekit] the upgraded Pro transaction was re-delivered and posted \(upgradedPosts.count) time(s)")
        XCTAssertTrue(upgradedPosts.allSatisfy { $0.payload.productId == CmuxProduct.proMonthly })
        try await rig.eventually("every delivered transaction finished") { await self.rig.unfinishedIDs().isEmpty }
        await PlansSnapshot.attach(rig.model, name: "10-upgraded-to-max", to: self)
    }

    // MARK: - Cancel

    /// Cancel = auto-renew off, then expiry. Turning auto-renew off creates no
    /// transaction: StoreKit reports it in the renewal info (and may
    /// re-deliver the current transaction unchanged, which the app posts
    /// again), and the plan stays until the period ends. At expiry
    /// StoreKit drops the entitlement (and may re-deliver the transaction
    /// with its expiry moved to now); the server learns of it from Apple, and
    /// on its next refresh the plans screen shows Free with no current
    /// product and no refund target.
    func testCancelThenExpiry() async throws {
        let transactionID = try await buy(CmuxProduct.proMonthly)
        let postsAfterBuy = rig.server.posts.count
        let testTransaction = try XCTUnwrap(rig.testTransactions(CmuxProduct.proMonthly).last)

        try rig.session.disableAutoRenewForTransaction(identifier: testTransaction.identifier)
        rig.dump("after disableAutoRenew")
        try await rig.eventually("auto-renew off in the renewal info") {
            try await self.rig.subscriptionStatuses().contains { status in
                if case .verified(let info) = status.renewalInfo { return !info.willAutoRenew }
                return false
            }
        }
        let cancelPosts = rig.server.posts.dropFirst(postsAfterBuy)
        XCTAssertTrue(cancelPosts.allSatisfy { $0.payload.transactionID == transactionID && $0.payload.revocationDate == nil },
                      "auto-renew off creates no transaction")
        print("[storekit] auto-renew off re-delivered the transaction \(cancelPosts.count) time(s)")
        let cancelled = try XCTUnwrap(rig.server.posts.last { $0.payload.transactionID == transactionID }?.payload)
        XCTAssertGreaterThan(try XCTUnwrap(cancelled.expires), Date(), "access lasts until the period ends")
        await rig.model.refresh()
        XCTAssertEqual(rig.model.account.account?.currentPlan, BillingCurrentPlan(planID: .pro, source: .apple))
        XCTAssertEqual(rig.model.currentAppleProductID, CmuxProduct.proMonthly)
        XCTAssertEqual(rig.model.currentAppleTransactionID, transactionID)
        await PlansSnapshot.attach(rig.model, name: "03-cancelled-auto-renew-off", to: self)

        let postsBeforeExpiry = rig.server.posts.count
        try rig.session.expireSubscription(productIdentifier: CmuxProduct.proMonthly)
        rig.dump("after expireSubscription")
        // StoreKit Testing can still renew at expireSubscription although its
        // renewal info already says auto-renew is off (run 45344114175: a
        // RENEWAL #1 with autoRenew=true appeared at expiry). Each such
        // renewal gets auto-renew off and is expired in turn, so the test
        // still ends on an expired subscription. The wait ends only when no
        // entitlement is listed and no Pro transaction is still unexpired, so
        // a renewal that lands after the entitlement dropped is not missed;
        // more than three stray renewals fail at once.
        var expiredRenewals: Set<UInt> = [testTransaction.identifier]
        try await rig.eventually("the expired entitlement dropped") {
            let live = self.rig.testTransactions(CmuxProduct.proMonthly).filter {
                !expiredRenewals.contains($0.identifier) && ($0.expirationDate ?? .distantPast) > Date()
            }
            if live.isEmpty, await self.rig.entitledProductIDs().isEmpty { return true }
            for renewal in live {
                expiredRenewals.insert(renewal.identifier)
                guard expiredRenewals.count <= 4 else {
                    XCTFail("StoreKit kept renewing at expiry with auto-renew off: \(expiredRenewals.sorted())")
                    throw CancellationError()
                }
                print("[storekit] StoreKit renewed #\(renewal.identifier) at expiry with auto-renew off; expiring it")
                try? self.rig.session.disableAutoRenewForTransaction(identifier: renewal.identifier)
                try? self.rig.session.expireSubscription(productIdentifier: CmuxProduct.proMonthly)
            }
            return false
        }
        let expiryPosts = rig.server.posts.dropFirst(postsBeforeExpiry)
        XCTAssertTrue(expiryPosts.allSatisfy { $0.payload.revocationDate == nil }, "expiry revokes nothing")
        XCTAssertTrue(expiryPosts.allSatisfy {
            $0.payload.transactionID == transactionID
                || ($0.payload.originalTransactionID == cancelled.originalTransactionID && $0.payload.transactionReason == "RENEWAL")
        }, "expiry creates no transaction but StoreKit Testing's stray renewal of the same subscription")
        print("[storekit] expiry re-delivered the transaction \(expiryPosts.filter { $0.payload.transactionID == transactionID }.count) "
            + "time(s); stray renewals posted: \(expiryPosts.filter { $0.payload.transactionID != transactionID }.count)")

        rig.server.receiveExpiredNotification(originalTransactionID: cancelled.originalTransactionID)
        await rig.model.refresh()
        XCTAssertEqual(rig.model.account.account?.currentPlan, BillingCurrentPlan(planID: .free, source: .none))
        XCTAssertNil(rig.model.currentAppleProductID)
        XCTAssertNil(rig.model.currentAppleTransactionID)
        try await rig.eventually("every re-delivery finished") { await self.rig.unfinishedIDs().isEmpty }
        await PlansSnapshot.attach(rig.model, name: "05-expired-free", to: self)
    }

    // MARK: - Refund

    /// A refund arrives on `Transaction.updates` as the same transaction with
    /// a revocation date. The app posts it, finishes it, and reloads the
    /// account: free plan, no current product, no refund transaction id.
    func testRefundPostsRevokedTransactionAndClearsPlan() async throws {
        let transactionID = try await buy(CmuxProduct.proMonthly)
        let testTransaction = try XCTUnwrap(rig.testTransactions(CmuxProduct.proMonthly).last)
        XCTAssertEqual(rig.model.currentAppleTransactionID, transactionID, "the refund sheet targets the purchase")

        try rig.session.refundTransaction(identifier: testTransaction.identifier)
        try await rig.waitUntil("the refunded transaction is posted") { !self.rig.server.refundPosts.isEmpty }
        rig.dump("after refundTransaction")

        let refund = try XCTUnwrap(rig.server.refundPosts.first?.payload)
        XCTAssertEqual(refund.transactionID, transactionID, "the refund revokes the purchased transaction itself")
        XCTAssertEqual(refund.productId, CmuxProduct.proMonthly)
        XCTAssertNotNil(refund.revocationDate)
        try await rig.waitUntil("the account reloads as free, with no refund target") {
            self.rig.model.account.account?.currentPlan == BillingCurrentPlan(planID: .free, source: .none)
                && self.rig.model.currentAppleTransactionID == nil
        }
        XCTAssertNil(rig.model.currentAppleProductID)
        // The revocation is finished after the server accepted it; another
        // delivery's account reload can show free first.
        try await rig.eventually("the revocation finished") {
            await !self.rig.unfinishedIDs().contains(transactionID)
        }
        try await rig.eventually("the refunded entitlement dropped") { await self.rig.entitledProductIDs().isEmpty }
        await PlansSnapshot.attach(rig.model, name: "06-refunded-free", to: self)
    }

    // MARK: - Renewal

    /// A renewal is a new transaction on `Transaction.updates`: posted,
    /// finished, and the refund sheet now targets it.
    func testRenewalPostsNewTransaction() async throws {
        let firstID = try await buy(CmuxProduct.proMonthly)
        let original = try XCTUnwrap(rig.server.purchasePosts.first { $0.payload.transactionID == firstID }?.payload)
            .originalTransactionID
        try rig.session.forceRenewalOfSubscription(productIdentifier: CmuxProduct.proMonthly)
        func renewals() -> [FakeCmuxBillingServer.Post] {
            rig.server.posts(original: original).filter {
                $0.payload.transactionReason == "RENEWAL" && $0.payload.transactionID != firstID
            }
        }
        try await rig.waitUntil("the renewal is posted") { !renewals().isEmpty }
        rig.dump("after forceRenewal")
        let renewal = try XCTUnwrap(renewals().first?.payload)
        XCTAssertEqual(renewal.productId, CmuxProduct.proMonthly)
        try await rig.waitUntil("the refund target moves to the renewal") {
            self.rig.model.currentAppleTransactionID == renewal.transactionID
        }
        XCTAssertEqual(rig.model.account.account?.currentPlan.planID, .pro)
        // Another delivery's account reload can move the refund target to the
        // renewal (it reads the entitlements) before the renewal's own post
        // finishes it (run 45320509297), so this waits for the finish.
        try await rig.eventually("the renewal finished") {
            await !self.rig.unfinishedIDs().contains(renewal.transactionID)
        }
        await PlansSnapshot.attach(rig.model, name: "07-renewed-pro", to: self)
    }

    /// Billing retry with a grace period: the failed renewal creates no
    /// transaction (StoreKit may re-deliver the current one with its expiry
    /// moved to now); StoreKit reports the grace period and keeps the
    /// entitlement. With the server told of the grace period (as Apple tells
    /// the real one), the plan and the current product stay.
    func testBillingRetryWithGraceKeepsPlan() async throws {
        rig.session.shouldEnterBillingRetryOnRenewal = true
        rig.session.billingGracePeriodIsEnabled = true
        let transactionID = try await buy(CmuxProduct.proMonthly)
        let purchase = try XCTUnwrap(rig.server.purchasePosts.first { $0.payload.transactionID == transactionID }?.payload)

        try rig.session.forceRenewalOfSubscription(productIdentifier: CmuxProduct.proMonthly)
        var grace: Date?
        try await rig.eventually("the grace period") {
            for status in try await self.rig.subscriptionStatuses() where status.state == .inGracePeriod {
                if case .verified(let info) = status.renewalInfo { grace = info.gracePeriodExpirationDate }
                return true
            }
            return false
        }
        rig.dump("after forceRenewal in billing retry + grace")
        let graceEnd = try XCTUnwrap(grace, "renewal info names the end of the grace period")
        XCTAssertGreaterThan(graceEnd, Date())
        XCTAssertFalse(rig.server.posts(original: purchase.originalTransactionID).contains { $0.payload.transactionID != transactionID },
                       "a failed renewal creates no transaction")
        let failed = purchase
        let entitled = await rig.entitledProductIDs()
        XCTAssertEqual(entitled, [CmuxProduct.proMonthly], "grace keeps the entitlement")

        rig.server.receiveGracePeriod(originalTransactionID: failed.originalTransactionID, until: graceEnd)
        await rig.model.refresh()
        XCTAssertEqual(rig.model.account.account?.currentPlan, BillingCurrentPlan(planID: .pro, source: .apple))
        XCTAssertEqual(rig.model.currentAppleProductID, CmuxProduct.proMonthly)
        XCTAssertEqual(rig.model.currentAppleTransactionID, transactionID)
        await PlansSnapshot.attach(rig.model, name: "08-billing-retry-grace", to: self)
    }

    /// Billing retry without a grace period: StoreKit drops the entitlement
    /// (and may re-deliver the transaction with its expiry moved to now). On
    /// its next refresh the plans screen loses its current product and refund
    /// target even while the server still grants the plan; the plan ends when
    /// the server hears of it (the lapsed re-delivery, or Apple).
    func testBillingRetryWithoutGraceEndsPlan() async throws {
        rig.session.shouldEnterBillingRetryOnRenewal = true
        let transactionID = try await buy(CmuxProduct.proMonthly)

        try rig.session.forceRenewalOfSubscription(productIdentifier: CmuxProduct.proMonthly)
        try await rig.eventually("the billing retry period") {
            try await self.rig.subscriptionStatuses().contains { $0.state == .inBillingRetryPeriod }
        }
        rig.dump("after forceRenewal in billing retry")
        try await rig.eventually("no entitlement in billing retry without grace") {
            await self.rig.entitledProductIDs().isEmpty
        }
        let original = try XCTUnwrap(rig.server.purchasePosts.first { $0.payload.transactionID == transactionID }?.payload)
        XCTAssertFalse(rig.server.posts(original: original.originalTransactionID).contains { $0.payload.transactionID != transactionID },
                       "a failed renewal creates no transaction")
        await rig.model.refresh()
        let planBeforeServerKnows = rig.model.account.account?.currentPlan
        print("[storekit] plan after the failed renewal, before Apple tells the server: \(String(describing: planBeforeServerKnows))")
        XCTAssertNil(rig.model.currentAppleProductID, "no StoreKit entitlement, so no current product or refund target")
        XCTAssertNil(rig.model.currentAppleTransactionID)
        rig.server.receiveExpiredNotification(originalTransactionID: original.originalTransactionID)
        await rig.model.refresh()
        XCTAssertEqual(rig.model.account.account?.currentPlan, BillingCurrentPlan(planID: .free, source: .none))
        XCTAssertNil(rig.model.currentAppleProductID)
        await PlansSnapshot.attach(rig.model, name: "09-billing-retry-no-grace", to: self)
    }

    // MARK: - Ask to Buy

    /// Ask to Buy: the purchase returns pending; approval delivers the
    /// transaction on `Transaction.updates`, which completes the purchase.
    /// The plans screen stays open here (no snapshot before the approval: a
    /// render closes the screen, which the next test covers).
    func testAskToBuyPendingThenApproved() async throws {
        rig.session.askToBuyEnabled = true
        await rig.model.buy(try rig.offer(CmuxProduct.proMonthly), entryPoint: .settings)
        XCTAssertEqual(rig.model.purchase, .pending(productID: CmuxProduct.proMonthly))
        XCTAssertEqual(rig.server.purchasePosts.count, 0, "nothing to post while approval is pending")

        try await approveAskToBuy()
        XCTAssertEqual(rig.model.purchase, .completed(.pro))
        try await rig.eventually("the approved entitlement") {
            await self.rig.entitledProductIDs() == [CmuxProduct.proMonthly]
        }
        await rig.model.refresh()
        XCTAssertEqual(rig.model.currentAppleProductID, CmuxProduct.proMonthly)
        await PlansSnapshot.attach(rig.model, name: "12-ask-to-buy-approved", to: self)
    }

    /// The person leaves the plans screen while Ask to Buy is pending (its
    /// `onDisappear` dismisses the result banner); the approval, minutes or
    /// hours later, must still complete the purchase.
    func testAskToBuyApprovedAfterLeavingPlansScreen() async throws {
        rig.session.askToBuyEnabled = true
        await rig.model.buy(try rig.offer(CmuxProduct.proMonthly), entryPoint: .settings)
        XCTAssertEqual(rig.model.purchase, .pending(productID: CmuxProduct.proMonthly))
        // Rendering the real screen runs its .task and, when the window goes
        // away, its onDisappear (dismissResult()), as leaving it does.
        await PlansSnapshot.attach(rig.model, name: "11-ask-to-buy-pending", to: self)
        rig.model.dismissResult()

        try await approveAskToBuy()
        XCTAssertEqual(rig.model.purchase, .completed(.pro), "the approval still completes the purchase")
    }

    /// Ask to Buy declined: no transaction ever arrives and nothing is posted.
    func testAskToBuyDeclined() async throws {
        rig.session.askToBuyEnabled = true
        await rig.model.buy(try rig.offer(CmuxProduct.proMonthly), entryPoint: .settings)
        let pending = try XCTUnwrap(rig.testTransactions(CmuxProduct.proMonthly).last { $0.pendingAskToBuyConfirmation })
        try rig.session.declineAskToBuyTransaction(identifier: pending.identifier)
        rig.dump("after declineAskToBuy")
        await rig.model.refresh()
        XCTAssertEqual(rig.server.purchasePosts.count, 0)
        XCTAssertEqual(rig.model.account.account?.currentPlan.planID, .free)
        XCTAssertEqual(rig.model.purchase, .pending(productID: CmuxProduct.proMonthly), "StoreKit never reports a decline")
    }

    // MARK: - Interrupted purchase

    /// An interrupted purchase (the person must act, such as accept new
    /// terms) returns `.pending`; resolving the issue delivers a new
    /// transaction on `Transaction.updates`, which the app posts and grants.
    func testInterruptedPurchaseResolvedLater() async throws {
        rig.session.interruptedPurchasesEnabled = true
        await rig.model.buy(try rig.offer(CmuxProduct.proMonthly), entryPoint: .settings)
        rig.dump("after interrupted purchase")
        XCTAssertEqual(rig.server.purchasePosts.count, 0, "an interrupted purchase has no completed transaction yet")
        XCTAssertEqual(rig.model.purchase, .pending(productID: CmuxProduct.proMonthly),
                       "StoreKit 2 returns .pending for an interrupted purchase")
        await PlansSnapshot.attach(rig.model, name: "13-interrupted-purchase", to: self)

        let interrupted = try XCTUnwrap(rig.testTransactions(CmuxProduct.proMonthly).last)
        rig.session.interruptedPurchasesEnabled = false
        try rig.session.resolveIssueForTransaction(identifier: interrupted.identifier)
        try await rig.waitUntil("the resolved purchase is posted") { !self.rig.server.purchasePosts.isEmpty }
        try await rig.waitUntil("the account shows Pro") {
            self.rig.model.account.account?.currentPlan.planID == .pro
        }
        let resolved = try XCTUnwrap(rig.server.purchasePosts.first?.payload)
        XCTAssertEqual(resolved.productId, CmuxProduct.proMonthly)
        XCTAssertEqual(rig.model.purchase, .completed(.pro))
        // Known limit, pinned here: under StoreKit Testing the resolved
        // transaction carries no appAccountToken (StoreKit completed it
        // outside the purchase call), so the model does not match it to this
        // account: no current product, no Manage-the-product or refund row.
        // The server still grants the plan (it lets the signed-in user claim
        // a token-less transaction no other account owns). Whether a real
        // App Store interrupted purchase also drops the token is unverified.
        XCTAssertNil(resolved.appAccountToken)
        XCTAssertNil(rig.model.currentAppleProductID)
        await PlansSnapshot.attach(rig.model, name: "14-interrupted-purchase-resolved", to: self)
    }

    // MARK: - Helpers

    /// Buys a product through the model, then waits until StoreKit lists it
    /// among the current entitlements and the model has read them.
    /// - Returns: The purchased transaction's id.
    private func buy(_ productID: String) async throws -> UInt64 {
        let postsBefore = rig.server.posts.count
        await rig.model.buy(try rig.offer(productID), entryPoint: .settings)
        XCTAssertEqual(rig.model.purchase, .completed(CmuxProduct.plan(of: productID)), "purchase of \(productID)")
        let post = try XCTUnwrap(rig.server.posts.dropFirst(postsBefore).last { $0.payload.productId == productID })
        try await rig.eventually("\(productID) among the current entitlements") {
            await self.rig.entitledProductIDs().contains(productID)
        }
        if rig.model.currentAppleProductID != productID {
            // storekitd lists a new purchase a moment after purchase()
            // returns; the plans screen reads it on its next refresh.
            print("[storekit] \(productID) was not yet entitled when the model read entitlements; refreshing")
            await rig.model.refresh()
        }
        XCTAssertEqual(rig.model.currentAppleProductID, productID)
        return post.payload.transactionID
    }

    private func approveAskToBuy() async throws {
        let pending = try XCTUnwrap(rig.testTransactions(CmuxProduct.proMonthly).last { $0.pendingAskToBuyConfirmation })
        try rig.session.approveAskToBuyTransaction(identifier: pending.identifier)
        try await rig.waitUntil("the approved purchase is posted") { !self.rig.server.purchasePosts.isEmpty }
        try await rig.waitUntil("the account shows Pro") {
            self.rig.model.account.account?.currentPlan.planID == .pro
        }
        rig.dump("after approveAskToBuy")
        XCTAssertEqual(rig.server.purchasePosts.first?.payload.productId, CmuxProduct.proMonthly)
        XCTAssertNil(rig.server.purchasePosts.first?.payload.revocationDate)
    }
}
