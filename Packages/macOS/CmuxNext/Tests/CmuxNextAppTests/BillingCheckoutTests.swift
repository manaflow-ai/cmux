@testable import CmuxNextApp
import Foundation
import Testing
import CmuxNextAccounts

/// `cmux billing checkout` (plans/cmux-next/paid-product-DESIGN.md sections 3-4): the page opens in
/// a cmux browser tab when the cmux browser is signed in to Stripe Link, else in the default
/// browser; a live-mode session is refused until live checkout is turned on.
@Suite struct BillingCheckoutTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test(arguments: [
        ("link.com", true), (".link.com", true), ("checkout.link.com", true), ("app.link.com", true),
        ("LINK.COM", true), ("checkout.stripe.com", false), ("m.stripe.com", false), (".stripe.com", false),
        ("notlink.com", false), ("link.com.evil.test", false), ("link.co", false), ("", false),
    ])
    func linkSessionCookieDomains(domain: String, expected: Bool) {
        #expect(StripeLinkCookieRule().matches(domain: domain, expires: nil, now: now) == expected)
    }

    @Test func anExpiredLinkCookieIsNoSession() {
        let rule = StripeLinkCookieRule()
        #expect(!rule.matches(domain: ".link.com", expires: now.addingTimeInterval(-1), now: now))
        #expect(rule.matches(domain: ".link.com", expires: now.addingTimeInterval(60), now: now))
        let cookies = [("m.stripe.com", nil), (".link.com", now.addingTimeInterval(-5))] as [(String, Date?)]
        #expect(!rule.hasSession(cookies, now: now))
        #expect(rule.hasSession(cookies + [("link.com", nil)], now: now))
    }

    @Test func chromiumExpiryIsMicrosecondsSince1601() {
        // 13_000_000_000_000_000 µs after 1601-01-01 is 2012-12-17.
        let date = StripeLinkCookieRule.chromiumDate(13_000_000_000_000_000)
        #expect(abs(date.timeIntervalSince1970 - 1_355_526_400) < 1)
    }

    @Test(arguments: [
        // request, link session, default browser is cmux, cmux browser on -> target
        (BillingOpenRequest.auto, true, false, true, BillingOpenTarget.cmuxBrowser),
        (.auto, false, false, true, .defaultBrowser),
        (.auto, false, true, true, .cmuxBrowser),
        (.auto, true, false, false, .defaultBrowser),
        (.cmux, false, false, true, .cmuxBrowser),
        (.cmux, false, false, false, .defaultBrowser),
        (.default, true, false, true, .defaultBrowser),
        (.default, true, true, true, .cmuxBrowser),
        (.printOnly, true, false, true, .nowhere),
    ])
    func openDecision(request: BillingOpenRequest, link: Bool, defaultIsCmux: Bool, cmuxBrowserOn: Bool, expected: BillingOpenTarget) {
        let target = BillingCheckoutOpener(defaultBrowserIsCmux: defaultIsCmux, cmuxBrowserEnabled: cmuxBrowserOn)
            .decide(request, linkSession: link)
        #expect(target == expected)
    }

    @Test func openRequestParsesTheCLIWords() {
        #expect(BillingOpenRequest(word: nil) == .auto)
        #expect(BillingOpenRequest(word: "cmux") == .cmux)
        #expect(BillingOpenRequest(word: "default") == .default)
        #expect(BillingOpenRequest(word: "none") == .printOnly)
        #expect(BillingOpenRequest(word: "safari") == nil)
    }

    @Test func stripeModeOfACheckoutURL() throws {
        let test = try #require(URL(string: "https://checkout.stripe.com/c/pay/cs_test_a1B2#fid=x"))
        let live = try #require(URL(string: "https://checkout.stripe.com/c/pay/cs_live_a1B2"))
        let portalLive = try #require(URL(string: "https://billing.stripe.com/p/session/live_YWNjdF8x"))
        let portalTest = try #require(URL(string: "https://billing.stripe.com/p/session/test_YWNjdF8x"))
        let welcome = try #require(URL(string: "https://cmux.com/dashboard/billing?welcome=pro"))
        #expect(StripeCheckoutMode(url: test) == .test)
        #expect(StripeCheckoutMode(url: live) == .live)
        #expect(StripeCheckoutMode(url: portalLive) == .live)
        #expect(StripeCheckoutMode(url: portalTest) == .test)
        #expect(StripeCheckoutMode(url: welcome) == .unknown)
    }

    @Test func liveCheckoutIsRefusedUntilTurnedOn() throws {
        let live = try #require(URL(string: "https://checkout.stripe.com/c/pay/cs_live_a1B2"))
        let test = try #require(URL(string: "https://checkout.stripe.com/c/pay/cs_test_a1B2"))
        #expect(BillingLivePolicy(liveCheckout: false).refuses(live))
        #expect(!BillingLivePolicy(liveCheckout: false).refuses(test))
        #expect(!BillingLivePolicy(liveCheckout: true).refuses(live))
        #expect(BillingLivePolicy.shipped.liveCheckout == false)
    }

    @Test func checkoutBodyCarriesOnlyThePlanAndTheTeam() throws {
        let pro = try BillingCheckoutRequest(plan: "pro", team: "t_ignored").body
        #expect(Set(pro.keys) == ["plan"])
        #expect(pro["plan"] as? String == "pro")
        let team = try BillingCheckoutRequest(plan: "team", team: " t_1 ").body
        #expect(team["plan"] as? String == "team")
        #expect(team["teamId"] as? String == "t_1")
        #expect(throws: BillingCheckoutRequest.Invalid.self) { try BillingCheckoutRequest(plan: "go", team: nil) }
        #expect(throws: BillingCheckoutRequest.Invalid.self) { try BillingCheckoutRequest(plan: "team", team: nil) }
    }
}
