import CmuxTerminalRenderCore
import Testing

@Suite struct TerminalLinkPolicyTests {
    let policy = TerminalLinkPolicy()

    @Test(arguments: ["https://cmux.com/docs", "http://localhost:3000/x", "mailto:dev@cmux.com", "ssh://dev@mini.local"])
    func opens(_ link: String) {
        #expect(policy.url(for: link)?.absoluteString == link)
    }

    @Test func bareWWWBecomesHTTPS() {
        #expect(policy.url(for: " www.cmux.com/a ")?.absoluteString == "https://www.cmux.com/a")
    }

    @Test(arguments: ["javascript:alert(1)", "file:///etc/passwd", "data:text/html,x", "cmux://open", "tel:123",
                      "", "https://", "https://evil.com/\u{7}", "relative/path"])
    func refuses(_ link: String) {
        #expect(policy.url(for: link) == nil)
    }

    @Test func refusesOverlongLinks() {
        #expect(policy.url(for: "https://cmux.com/" + String(repeating: "a", count: 5000)) == nil)
    }

    @Test func schemesAreCaseInsensitive() {
        #expect(policy.url(for: "HTTPS://cmux.com") != nil)
        #expect(TerminalLinkPolicy(allowedSchemes: ["HTTPS"]).url(for: "https://cmux.com") != nil)
    }
}
