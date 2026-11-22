@testable import CmuxNextApp
import CmuxNextAccounts
import CmuxNextAppCore
import CmuxNextTestSupport
import Foundation
import Testing

/// One upgrade path from every paywall (plans/cmux-next/paid-plans-DESIGN.md §2, gaps 1, 2 and 4):
/// a paywall asks cmux.com for a Checkout page that returns to this app, falls back to the refusal's
/// link or pricing, and the plan turning paid after that shows the welcome step once.
@MainActor @Suite struct PaidPlanUpgradeTests {
    final class Calls {
        var opened: [URL] = []
        var asked: [(plan: String, scheme: String)] = []
    }

    let defaults: UserDefaults
    var now = Date(timeIntervalSince1970: 1_800_000_000)

    init() {
        let suite = "PaidPlanUpgradeTests.\(UUID().uuidString)"
        defaults = UserDefaults(testSuiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
    }

    func onboarding(at date: Date? = nil) -> PaidPlanOnboarding {
        let at = date ?? now
        return PaidPlanOnboarding(defaults: defaults, now: { at })
    }

    func upgrade(_ calls: Calls, checkout: (@MainActor (String, String) async throws -> URL)?) -> PaidPlanUpgrade {
        PaidPlanUpgrade(checkout: checkout, open: { calls.opened.append($0) }, scheme: "cmux-next", onboarding: onboarding(), pricing: StaticURL.pricing.url)
    }

    @Test func aSignedInPaywallOpensCheckoutThatReturnsToThisApp() async {
        let calls = Calls()
        let page = URL(string: "https://checkout.stripe.com/c/pay/cs_test_abc")!
        let outcome = await upgrade(calls) { plan, scheme in calls.asked.append((plan, scheme)); return page }
            .start(plan: "pro", source: .cloudCreate)
        #expect(outcome == .checkout(page))
        #expect(calls.opened == [page])
        #expect(calls.asked.map(\.plan) == ["pro"])
        #expect(calls.asked.map(\.scheme) == ["cmux-next"])
    }

    @Test func aCheckoutFailureOpensTheRefusalsLinkElsePricing() async {
        struct Down: Error {}
        let calls = Calls()
        let refusal = URL(string: "https://cmux.com/pricing?plan=pro&from=cloud")!
        let first = await upgrade(calls) { _, _ in throw Down() }.start(source: .cloudRefusal, fallback: refusal)
        #expect(first == .pricing(refusal))
        let second = await upgrade(calls) { _, _ in throw Down() }.start(source: .palette)
        #expect(second == .pricing(StaticURL.pricing.url))
        #expect(calls.opened == [refusal, StaticURL.pricing.url])
    }

    @Test func signedOutOpensPricingWithoutAskingForCheckout() async {
        let calls = Calls()
        let outcome = await upgrade(calls, checkout: nil).start(source: .palette)
        #expect(outcome == .pricing(StaticURL.pricing.url))
        #expect(calls.asked.isEmpty)
    }

    /// A cmux NEXT plan opens cmux.com's checkout page for it (`api/billing/checkout?plan=`), signed in or out, never the
    /// native checkout; a classic plan keeps the native one.
    @Test func aNextPlanOpensItsWebCheckoutPage() async {
        let web = URL(string: "https://cmux.com")!
        for plan in ["next_plus", "next_pro", "next_max"] {
            let calls = Calls()
            var next = upgrade(calls) { plan, scheme in calls.asked.append((plan, scheme)); return StaticURL.pricing.url }
            next.web = web
            let page = URL(string: "https://cmux.com/api/billing/checkout?plan=\(plan)")!
            #expect(await next.start(plan: plan, source: .cloudRefusal) == .checkout(page))
            #expect(calls.opened == [page] && calls.asked.isEmpty)
        }
        #expect(PaidPlanUpgrade.plan("next_pro") == "next_pro" && PaidPlanUpgrade.plan("next_max") == "next_max")
        #expect(PaidPlanUpgrade.plan("max") == "max" && PaidPlanUpgrade.plan("team") == "pro" && PaidPlanUpgrade.plan(nil) == "pro")
        #expect(BillingStrings.planName("next_pro") == "cmux NEXT Pro" && BillingStrings.planName("next_max") == "cmux NEXT Max")
        #expect(PaidPlanUpgrade.plan("next_plus") == "next_plus" && BillingStrings.planName("next_plus") == "cmux NEXT Plus")
    }

    @Test func aLiveModeCheckoutIsNeverOpened() async {
        // Real charges stay off (BillingLivePolicy.shipped): a live session falls back to pricing.
        let calls = Calls()
        let live = URL(string: "https://checkout.stripe.com/c/pay/cs_live_abc")!
        let outcome = await upgrade(calls) { _, _ in live }.start(source: .palette)
        #expect(outcome == .pricing(StaticURL.pricing.url))
        #expect(!calls.opened.contains(live))
    }

    @Test func checkoutRequestCarriesTheReturnScheme() throws {
        let body = try BillingCheckoutRequest(plan: "pro", team: nil, scheme: "cmux-next").body
        #expect(body["cmux_scheme"] as? String == "cmux-next")
        #expect(try BillingCheckoutRequest(plan: "pro", team: nil).body["cmux_scheme"] == nil)
    }

    // MARK: Onboarding

    @Test func thePlanTurningPaidAfterAnUpgradeWelcomesOnce() {
        let o = onboarding()
        o.markPending("pro")
        #expect(o.hasPending)
        #expect(o.observe(planID: "free", account: "u1") == nil, "still free: keep waiting")
        #expect(o.hasPending)
        #expect(o.observe(planID: "pro", account: "u1") == PaidPlanOnboarding.Welcome(plan: "pro"))
        #expect(!o.hasPending)
        #expect(o.observe(planID: "pro", account: "u1") == nil, "the welcome shows once")
    }

    @Test func aPlanThePersonAlreadyHadShowsNoWelcome() {
        let o = onboarding()
        #expect(o.observe(planID: "pro", account: "u1") == nil)
        #expect(o.observe(planID: nil, account: "u1") == nil)
    }

    @Test func aProPersonWhoOpensUpgradeGetsNoWelcomeUntilThePlanChanges() {
        let o = onboarding()
        #expect(o.observe(planID: "pro", account: "u1") == nil)
        o.markPending("max")
        #expect(o.observe(planID: "pro", account: "u1") == nil, "still Pro: no welcome to Pro")
        #expect(o.observe(planID: "max", account: "u1") == PaidPlanOnboarding.Welcome(plan: "max"))
    }

    @Test func aStaleUpgradeShowsNoWelcome() {
        onboarding().markPending("pro")
        let later = onboarding(at: now.addingTimeInterval(2 * 86_400))
        #expect(!later.hasPending)
        #expect(later.observe(planID: "pro", account: "u1") == nil)
    }

    @Test func theWelcomeIsPerAccountAndPlan() {
        let o = onboarding()
        o.markPending("pro")
        #expect(o.observe(planID: "pro", account: "u1") != nil)
        o.markPending("max")
        #expect(o.observe(planID: "max", account: "u1") == PaidPlanOnboarding.Welcome(plan: "max"))
        o.markPending("pro")
        #expect(o.observe(planID: "pro", account: "u2") == PaidPlanOnboarding.Welcome(plan: "pro"))
    }

    /// The pricing card's Subscribe names its plan through the one upgrade action (`palette.pro.upgrade {plan}`): Max
    /// asks Max's checkout, anything else Pro's.
    @Test func theUpgradeActionTakesThePlanItNames() {
        #expect(PaidPlanUpgrade.plan("max") == "max")
        #expect(PaidPlanUpgrade.plan("pro") == "pro")
        #expect(PaidPlanUpgrade.plan(nil) == "pro" && PaidPlanUpgrade.plan("team") == "pro")
    }
}
