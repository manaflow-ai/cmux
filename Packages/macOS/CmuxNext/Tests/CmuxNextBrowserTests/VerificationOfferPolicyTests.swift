@testable import CmuxNextBrowser
import Foundation
import Testing

/// The matching and origin rules of email verification AutoFill
/// (plans/cmux-next/email-verification-autofill/DESIGN.md, "Matching"): an
/// email's code or link reaches a page only on the sender's own site, in the
/// time window, in a person's https tab, with one clear answer.
@Suite struct VerificationOfferPolicyTests {
    static let start = Date(timeIntervalSince1970: 1_000_000)
    let policy = VerificationOfferPolicy(publicSuffixes: PublicSuffixList.bundled() ?? PublicSuffixList(listText: ""))

    static func signal(_ page: String, agentDriven: Bool = false, startedAt: Date = start) -> VerificationPageSignal {
        VerificationPageSignal(tab: BrowserTabID(rawValue: "tab-1"), pageURL: URL(string: page)!, startedAt: startedAt, agentDriven: agentDriven)
    }

    static func email(from sender: String = "noreply@github.com", authenticated: Bool? = true,
                      subject: String = "", body: String = "Your verification code is 482913.",
                      links: [String] = [], receivedAfter seconds: TimeInterval = 20) -> VerificationEmail {
        VerificationEmail(id: "m1", senderAddress: sender, senderAuthenticated: authenticated, subject: subject, body: body,
                          links: links.compactMap(URL.init(string:)), receivedAt: start.addingTimeInterval(seconds))
    }

    func decide(_ email: VerificationEmail, _ signal: VerificationPageSignal, enabled: Bool = true,
                now: Date = start.addingTimeInterval(60)) -> Result<VerificationOffer, VerificationOfferRejection> {
        policy.offer(for: email, on: signal, enabled: enabled, now: now)
    }

    // MARK: - Offers

    @Test func aSameSiteCodeIsOffered() throws {
        let offer = try decide(Self.email(from: "noreply@accounts.github.com"), Self.signal("https://github.com/sessions/verified-device")).get()
        #expect(offer.code == "482913")
        #expect(offer.link == nil)
        #expect(offer.senderSite == "github.com")
        #expect(offer.pageOrigin == "https://github.com")
        #expect(offer.expiresAt == Self.start.addingTimeInterval(20 + 600))
    }

    @Test func aSameSiteVerificationLinkIsOffered() throws {
        let email = Self.email(body: "Click below to confirm your email address.",
                               links: ["https://github.com/users/confirm_verification/abc", "https://github.com/settings/emails/unsubscribe"])
        let offer = try decide(email, Self.signal("https://github.com/signup")).get()
        #expect(offer.code == nil)
        #expect(offer.link?.absoluteString == "https://github.com/users/confirm_verification/abc")
    }

    @Test func anOriginBoundCodeIsOfferedOnItsExactHost() throws {
        let email = Self.email(from: "noreply@mailer.example.net", body: "Your code is 482913.\n@login.example.com #482913")
        let offer = try decide(email, Self.signal("https://login.example.com/otp")).get()
        #expect(offer.code == "482913")
    }

    // MARK: - Refusals: who and where

    @Test func nothingWhenTheFeatureIsOff() {
        #expect(decide(Self.email(), Self.signal("https://github.com/login"), enabled: false) == .failure(.featureOff))
    }

    @Test func nothingInAnAgentDrivenTab() {
        #expect(decide(Self.email(), Self.signal("https://github.com/login", agentDriven: true)) == .failure(.agentDrivenTab))
    }

    @Test(arguments: ["http://github.com/login", "file:///tmp/login.html", "data:text/html,code"])
    func nothingOnAnInsecurePage(page: String) {
        #expect(decide(Self.email(), Self.signal(page)) == .failure(.insecurePage))
    }

    /// The phishing case: a lookalike or attacker page never sees the real site's code.
    @Test(arguments: [
        "https://evil.com/login",
        "https://github.com.evil.io/login",
        "https://evil-github.com/login",
        "https://someone.github.io/login",
    ])
    func nothingOnAnotherSite(page: String) {
        #expect(decide(Self.email(), Self.signal(page)) == .failure(.differentSite))
    }

    @Test func nothingFromASenderWithoutASite() {
        #expect(decide(Self.email(from: "root@localhost"), Self.signal("https://github.com/login")) == .failure(.senderHasNoSite))
        #expect(decide(Self.email(from: "not an address"), Self.signal("https://github.com/login")) == .failure(.senderHasNoSite))
    }

    @Test func anOriginBoundCodeForAnotherHostIsRefused() {
        let email = Self.email(body: "Your code is 482913.\n@pay.github.com #482913")
        #expect(decide(email, Self.signal("https://github.com/login")) == .failure(.originBoundToAnotherHost))
    }

    // MARK: - Refusals: when

    @Test func nothingFromAnEmailBeforeThePageAsked() {
        #expect(decide(Self.email(receivedAfter: -61), Self.signal("https://github.com/login")) == .failure(.receivedBeforePageAsked))
        #expect((try? decide(Self.email(receivedAfter: -59), Self.signal("https://github.com/login")).get()) != nil)
    }

    @Test func nothingFromAnEmailLongAfterThePageAsked() {
        let late = Self.email(receivedAfter: 601)
        #expect(decide(late, Self.signal("https://github.com/login"), now: Self.start.addingTimeInterval(605)) == .failure(.receivedAfterWindow))
    }

    @Test func nothingFromAnOldEmail() {
        #expect(decide(Self.email(receivedAfter: 20), Self.signal("https://github.com/login"), now: Self.start.addingTimeInterval(621)) == .failure(.expired))
    }

    // MARK: - Refusals: what

    @Test func nothingWithoutACodeOrLink() {
        #expect(decide(Self.email(body: "Welcome to GitHub!"), Self.signal("https://github.com/login")) == .failure(.nothingToOffer))
    }

    @Test func nothingWhenTwoCodesDisagree() {
        let email = Self.email(body: "Your code is 111111.\nOld code: 222222")
        #expect(decide(email, Self.signal("https://github.com/login")) == .failure(.ambiguous))
    }

    @Test func nothingWhenTwoVerificationLinksDisagree() {
        let email = Self.email(body: "Confirm your email.",
                               links: ["https://github.com/confirm?t=1", "https://github.com/verify?t=2"])
        #expect(decide(email, Self.signal("https://github.com/signup")) == .failure(.ambiguous))
    }

    /// A link to another site in a same-site email is never offered.
    @Test func aCrossSiteLinkIsNotOffered() {
        let email = Self.email(body: "Confirm your email.", links: ["https://github.com.evil.io/confirm?t=1"])
        #expect(decide(email, Self.signal("https://github.com/signup")) == .failure(.nothingToOffer))
    }

    /// A spoofed sender could plant a link; a link needs a sender the source authenticated.
    @Test func aLinkFromAnUnauthenticatedSenderIsNotOffered() {
        let email = Self.email(authenticated: nil, body: "Confirm your email.", links: ["https://github.com/confirm?t=1"])
        #expect(decide(email, Self.signal("https://github.com/signup")) == .failure(.nothingToOffer))
        let failed = Self.email(authenticated: false, body: "Confirm your email.", links: ["https://github.com/confirm?t=1"])
        #expect(decide(failed, Self.signal("https://github.com/signup")) == .failure(.senderFailedAuthentication))
    }

    /// A code from a sender that failed authentication is refused; an unknown result still offers a code.
    @Test func aCodeFromASenderThatFailedAuthenticationIsRefused() throws {
        #expect(decide(Self.email(authenticated: false), Self.signal("https://github.com/login")) == .failure(.senderFailedAuthentication))
        #expect(try decide(Self.email(authenticated: nil), Self.signal("https://github.com/login")).get().code == "482913")
    }

    @Test func theOfferDescriptionIsRedacted() throws {
        let offer = try decide(Self.email(), Self.signal("https://github.com/login")).get()
        #expect(!String(describing: offer).contains("482913"))
        #expect(!String(reflecting: offer).contains("482913"))
    }
}
