import AppKit
@testable import CmuxNextBrowser
import Testing

/// The email verification offer in the prompt bar (DESIGN.md "Delivery"): Not Now, Open Link when
/// the email had a same-site link, Fill Code when it had a code, the code-filling button prominent.
/// Return answers the prominent button; the bar never answers by itself.
@MainActor @Suite(.serialized) struct VerificationPromptBarTests {
    static func offer(code: String?, link: URL?) -> VerificationOffer {
        VerificationOffer(emailID: "m1", tab: BrowserTabID(rawValue: "t"), senderSite: "github.com", pageOrigin: "https://github.com",
                          code: code, link: link, expiresAt: .distantFuture)
    }

    static func answers(code: String?, link: URL?) -> [String] {
        let bar = PromptBarView(frame: NSRect(x: 0, y: 0, width: 600, height: 80))
        bar.show(BrowserPrompt(kind: .verificationOffer(offer(code: code, link: link)), origin: "https://github.com") { _ in })
        return PasswordPromptBarTests.responseButtons(in: bar).map { String(describing: $0.response) }
    }

    static func name(_ response: BrowserPromptResponse) -> String { String(describing: BrowserPromptResponse?.some(response)) }

    @Test func aCodeAndLinkOfferNotNowOpenLinkAndFillCode() {
        #expect(Self.answers(code: "482913", link: URL(string: "https://github.com/verify")) == [Self.name(.cancel), Self.name(.allowOnce), Self.name(.accept)])
    }

    @Test func aLinkOnlyOfferHasNoFillCode() {
        #expect(Self.answers(code: nil, link: URL(string: "https://github.com/verify")) == [Self.name(.cancel), Self.name(.allowOnce)])
    }

    @Test func returnFillsTheCodeAndNeverAnswersText() {
        var answered: [BrowserPromptResponse] = []
        let bar = PromptBarView(frame: NSRect(x: 0, y: 0, width: 600, height: 80))
        bar.show(BrowserPrompt(kind: .verificationOffer(Self.offer(code: "482913", link: nil)), origin: "https://github.com") { answered.append($0) })
        bar.submit()
        #expect(answered == [.accept])
    }

    @Test func closingTheTabDeclinesTheOffer() {
        let prompt = BrowserPrompt(kind: .verificationOffer(Self.offer(code: "482913", link: nil)), origin: "https://github.com") { _ in }
        #expect(prompt.dismissalResponse == .cancel)
    }
}
