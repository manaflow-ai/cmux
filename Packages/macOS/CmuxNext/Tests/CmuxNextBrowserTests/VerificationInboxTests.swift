@testable import CmuxNextBrowser
import Foundation
import Testing

/// Offers live in memory, per tab, once (DESIGN.md, "Matching" rule 8 and
/// "Threat model"): taking one consumes it everywhere, a navigation to
/// another site or an expiry drops it, and turning the feature off clears all.
@MainActor @Suite struct VerificationInboxTests {
    static let start = Date(timeIntervalSince1970: 1_000_000)
    static let tabA = BrowserTabID(rawValue: "a")
    static let tabB = BrowserTabID(rawValue: "b")

    let inbox = VerificationInbox(policy: VerificationOfferPolicy(publicSuffixes: PublicSuffixList.bundled() ?? PublicSuffixList(listText: "")))

    static func signal(_ tab: BrowserTabID, _ page: String = "https://github.com/login") -> VerificationPageSignal {
        VerificationPageSignal(tab: tab, pageURL: URL(string: page)!, startedAt: start, agentDriven: false)
    }

    static func email(id: String = "m1", code: String = "482913") -> VerificationEmail {
        VerificationEmail(id: id, senderAddress: "noreply@github.com", senderAuthenticated: true, subject: "",
                          body: "Your verification code is \(code).", links: [], receivedAt: start.addingTimeInterval(10))
    }

    let now = start.addingTimeInterval(30)
    let page = URL(string: "https://github.com/sessions/two-factor")!

    @Test func anEmailOffersOnEveryWaitingTabOfItsSite() {
        inbox.pageStartedWaiting(Self.signal(Self.tabA))
        inbox.pageStartedWaiting(Self.signal(Self.tabB, "https://evil.com/login"))
        let offered = inbox.receive(Self.email(), enabled: true, now: now)
        #expect(offered == [Self.tabA])
        #expect(inbox.pendingOffer(for: Self.tabA, now: now)?.code == "482913")
        #expect(inbox.pendingOffer(for: Self.tabB, now: now) == nil)
    }

    @Test func noTabWaitingMeansNoOffer() {
        #expect(inbox.receive(Self.email(), enabled: true, now: now).isEmpty)
    }

    @Test func takingAnOfferUsesItUpEverywhere() {
        inbox.pageStartedWaiting(Self.signal(Self.tabA))
        inbox.pageStartedWaiting(Self.signal(Self.tabB))
        _ = inbox.receive(Self.email(), enabled: true, now: now)
        #expect(inbox.take(for: Self.tabA, currentURL: page, now: now)?.code == "482913")
        #expect(inbox.take(for: Self.tabA, currentURL: page, now: now) == nil)
        #expect(inbox.pendingOffer(for: Self.tabB, now: now) == nil)
        // The same email again (a source that re-reports it) never offers twice.
        #expect(inbox.receive(Self.email(), enabled: true, now: now).isEmpty)
    }

    @Test func declineUsesItUpToo() {
        inbox.pageStartedWaiting(Self.signal(Self.tabA))
        _ = inbox.receive(Self.email(), enabled: true, now: now)
        inbox.decline(for: Self.tabA)
        #expect(inbox.pendingOffer(for: Self.tabA, now: now) == nil)
        #expect(inbox.receive(Self.email(), enabled: true, now: now).isEmpty)
    }

    /// The navigation race: the tab moved to another site between offer and click.
    @Test func takeRefusesWhenTheTabLeftTheSite() {
        inbox.pageStartedWaiting(Self.signal(Self.tabA))
        _ = inbox.receive(Self.email(), enabled: true, now: now)
        #expect(inbox.take(for: Self.tabA, currentURL: URL(string: "https://evil.com/")!, now: now) == nil)
        #expect(inbox.pendingOffer(for: Self.tabA, now: now) == nil)
    }

    @Test func navigatingToAnotherSiteEndsTheWait() {
        inbox.pageStartedWaiting(Self.signal(Self.tabA))
        inbox.tabNavigated(Self.tabA, to: URL(string: "https://evil.com/")!)
        #expect(inbox.receive(Self.email(), enabled: true, now: now).isEmpty)
    }

    @Test func navigatingWithinTheSiteKeepsTheWait() {
        inbox.pageStartedWaiting(Self.signal(Self.tabA))
        inbox.tabNavigated(Self.tabA, to: page)
        #expect(inbox.receive(Self.email(), enabled: true, now: now) == [Self.tabA])
    }

    @Test func anOfferExpires() {
        inbox.pageStartedWaiting(Self.signal(Self.tabA))
        _ = inbox.receive(Self.email(), enabled: true, now: now)
        let later = Self.start.addingTimeInterval(10 + 601)
        #expect(inbox.pendingOffer(for: Self.tabA, now: later) == nil)
        #expect(inbox.take(for: Self.tabA, currentURL: page, now: later) == nil)
    }

    @Test func closingTheTabDropsItsOfferAndWait() {
        inbox.pageStartedWaiting(Self.signal(Self.tabA))
        _ = inbox.receive(Self.email(), enabled: true, now: now)
        inbox.tabClosed(Self.tabA)
        #expect(inbox.pendingOffer(for: Self.tabA, now: now) == nil)
        #expect(inbox.receive(Self.email(id: "m2"), enabled: true, now: now).isEmpty)
    }

    @Test func turningTheFeatureOffClearsEverything() {
        inbox.pageStartedWaiting(Self.signal(Self.tabA))
        _ = inbox.receive(Self.email(), enabled: true, now: now)
        inbox.clearAll()
        #expect(inbox.pendingOffer(for: Self.tabA, now: now) == nil)
        #expect(inbox.receive(Self.email(id: "m2"), enabled: true, now: now).isEmpty)
    }

    @Test func aNewerEmailReplacesTheOffer() {
        inbox.pageStartedWaiting(Self.signal(Self.tabA))
        _ = inbox.receive(Self.email(id: "m1", code: "111111"), enabled: true, now: now)
        _ = inbox.receive(Self.email(id: "m2", code: "222222"), enabled: true, now: now)
        #expect(inbox.pendingOffer(for: Self.tabA, now: now)?.code == "222222")
    }

    @Test func aDisabledFeatureOffersNothing() {
        inbox.pageStartedWaiting(Self.signal(Self.tabA))
        #expect(inbox.receive(Self.email(), enabled: false, now: now).isEmpty)
    }
}

extension VerificationInboxTests {
    /// The bar showed an older email's code; a newer email replaced the offer. A click on the
    /// old row must not hand out the new code.
    @Test func aClickOnAReplacedOfferTakesNothing() {
        inbox.pageStartedWaiting(Self.signal(Self.tabA))
        _ = inbox.receive(Self.email(id: "m1", code: "111111"), enabled: true, now: now)
        _ = inbox.receive(Self.email(id: "m2", code: "222222"), enabled: true, now: now)
        #expect(inbox.take(for: Self.tabA, emailID: "m1", currentURL: page, now: now) == nil)
        inbox.decline(for: Self.tabA, emailID: "m1")
        #expect(inbox.take(for: Self.tabA, emailID: "m2", currentURL: page, now: now)?.code == "222222")
    }

    @Test func reportsWhetherAnyPageWaits() {
        #expect(!inbox.hasWaitingPages)
        inbox.pageStartedWaiting(Self.signal(Self.tabA))
        #expect(inbox.hasWaitingPages)
        #expect(inbox.earliestWaitStart == Self.start)
    }
}
