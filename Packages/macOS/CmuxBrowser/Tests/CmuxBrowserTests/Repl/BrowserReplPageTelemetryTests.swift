import Testing

@testable import CmuxBrowser

/// A session's domain policy refuses its reads of a page it blocks; the
/// page's console messages and errors are reads too, and must not reach
/// the session while the tab shows such a page.
@Suite("Browser REPL page telemetry")
struct BrowserReplPageTelemetryTests {
    private func policy(allowed: [String]? = nil, prohibited: [String] = []) throws -> BrowserReplDomainPolicy {
        var policy = BrowserReplDomainPolicy()
        policy.allowed = try allowed?.map { try BrowserReplDomainPattern.parse($0, title: "t") }
        policy.prohibited = try prohibited.map { try BrowserReplDomainPattern.parse($0, title: "t") }
        return policy
    }

    @Test("Console messages and errors of a blocked page reach only the sessions whose policy allows it")
    func blockedPagesTelemetryReachesOnlyAllowingSessions() throws {
        let policies: [String: BrowserReplDomainPolicy] = [
            "allow-list": try policy(allowed: ["example.com"]),
            "prohibits": try policy(prohibited: ["evil.test"]),
        ]
        let sessions = ["allow-list", "open", "prohibits"]
        let telemetry = BrowserReplPageTelemetry()
        let evil = BrowserReplFrameDocument(origin: "https://evil.test", place: "https://evil.test")
        #expect(telemetry.recipients(of: evil, among: sessions) { policies[$0] } == ["open"])
        let fine = BrowserReplFrameDocument(origin: "https://example.com", place: "https://example.com")
        #expect(telemetry.recipients(of: fine, among: sessions) { policies[$0] } == sessions)
        let elsewhere = BrowserReplFrameDocument(origin: "https://other.test", place: "https://other.test")
        #expect(telemetry.recipients(of: elsewhere, among: sessions) { policies[$0] } == ["open", "prohibits"])
    }
}
