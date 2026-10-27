@testable import CmuxNextBrowser
import Foundation
import Testing

/// What the parser takes from a verification email: a code only next to a
/// code word, the origin-bound line, and https links. No guessing: years,
/// prices and order numbers are not codes.
@Suite struct VerificationMessageParserTests {
    let parser = VerificationMessageParser()

    static func email(subject: String = "", body: String, links: [URL] = []) -> VerificationEmail {
        VerificationEmail(id: "m1", senderAddress: "noreply@github.com", senderAuthenticated: true,
                          subject: subject, body: body, links: links, receivedAt: Date(timeIntervalSince1970: 1_000))
    }

    @Test(arguments: [
        ("", "Your verification code is 482913.", "482913"),
        ("", "Here is your code:\n\n  482913\n\nIt expires in 10 minutes.", "482913"),
        ("482913 is your GitHub code", "Thanks!", "482913"),
        ("", "Enter this one-time code: 482-913", "482913"),
        ("", "Your sign-in code is 482 913", "482913"),
        ("", "Use security code K7QX2M to continue.", "K7QX2M"),
        ("", "Votre code de vérification : 4829", "4829"),
    ])
    func findsTheCode(subject: String, body: String, code: String) {
        #expect(parser.parse(Self.email(subject: subject, body: body)).codes == [code])
    }

    @Test(arguments: [
        "Thanks for signing up. © 2026 GitHub, Inc.",
        "Your order #48291355 shipped. Total $1299.",
        "Call us at 415 555 0100.",
        "Welcome to GITHUB, ENJOY",
        "Your verification code expires in 2026.",
    ])
    func findsNoCode(body: String) {
        #expect(parser.parse(Self.email(body: body)).codes.isEmpty)
    }

    @Test func twoDifferentCodesAreBothReported() {
        let parsed = parser.parse(Self.email(body: "Your code is 111111.\nOld code: 222222"))
        #expect(parsed.codes == ["111111", "222222"])
    }

    @Test func theSameCodeTwiceIsOneCode() {
        let parsed = parser.parse(Self.email(subject: "Your code: 482913", body: "Your code is 482913."))
        #expect(parsed.codes == ["482913"])
    }

    @Test func readsTheOriginBoundLine() {
        let parsed = parser.parse(Self.email(body: "Your code is 482913.\n\n@github.com #482913"))
        #expect(parsed.originBoundCode == OriginBoundCode(host: "github.com", code: "482913"))
    }

    /// The embedded form (`@top #code @frame`) is for an iframe; cmux offers
    /// codes in the top frame only, so it is not read as a top-frame binding.
    @Test func ignoresTheEmbeddedOriginBoundForm() {
        let parsed = parser.parse(Self.email(body: "@shop.example #482913 @pay.example"))
        #expect(parsed.originBoundCode == nil)
    }

    @Test func keepsOnlySafeHTTPSLinks() throws {
        let links = try [
            "https://github.com/login/device/verify?token=abc",
            "http://github.com/verify?token=abc",
            "https://user:pw@github.com/verify",
            "https://github.com:8443/verify",
            "javascript:alert(1)",
        ].map { try #require(URL(string: $0)) }
        let parsed = parser.parse(Self.email(body: "Confirm your email.", links: links))
        #expect(parsed.links.map(\.absoluteString) == ["https://github.com/login/device/verify?token=abc"])
    }

    @Test func findsLinksInPlainText() {
        let parsed = parser.parse(Self.email(body: "Open https://github.com/confirm?t=1 to confirm."))
        #expect(parsed.links.map(\.absoluteString) == ["https://github.com/confirm?t=1"])
    }

    /// Sentence punctuation after a link is not part of it (NSDataDetector on macOS, the https
    /// pattern on Linux, p15-oracle-140).
    @Test func aLinkEndsBeforeSentencePunctuation() {
        let parsed = parser.parse(Self.email(body: "Confirm at https://github.com/confirm?t=1. Or (https://github.com/c/2), thanks!"))
        #expect(parsed.links.map(\.absoluteString) == ["https://github.com/confirm?t=1", "https://github.com/c/2"])
    }

    /// An email's description never shows its text: a log line or crash
    /// report must not carry a code.
    @Test func theEmailDescriptionIsRedacted() {
        let email = Self.email(subject: "482913 is your code", body: "Your code is 482913.")
        #expect(!String(describing: email).contains("482913"))
        #expect(!String(reflecting: email).contains("482913"))
    }
}
