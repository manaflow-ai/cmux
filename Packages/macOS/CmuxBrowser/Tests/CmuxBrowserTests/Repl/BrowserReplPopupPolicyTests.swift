import CmuxSettings
import Foundation
import Testing

@testable import CmuxBrowser

/// A window a page opens from a tab a REPL session drives becomes a new tab
/// that cmux opens itself, through the navigation that trusts local files
/// and cmux's internal schemes. The page controls the URL, so it must pass
/// as an untrusted navigation first.
@Suite("Browser REPL page-opened windows")
struct BrowserReplPopupPolicyTests {
    private let open = BrowserURLAllowlistPolicy(managedPatterns: nil)

    private func policy(allowed: [String]? = nil, prohibited: [String] = []) throws -> BrowserReplDomainPolicy {
        var policy = BrowserReplDomainPolicy()
        policy.allowed = try allowed?.map { try BrowserReplDomainPattern.parse($0, title: "t") }
        policy.prohibited = try prohibited.map { try BrowserReplDomainPattern.parse($0, title: "t") }
        return policy
    }

    @Test("Local files and cmux's internal schemes never open from a page, with or without a policy",
          arguments: [
              "file:///etc/passwd",
              "file://localhost/Users/me/.ssh/id_ed25519",
              "data:text/html,<script>alert(1)</script>",
              "javascript:alert(1)",
              "cmux-diff-viewer://session/index.html",
              "cmux-browser-action://open",
              "applewebdata://x/y",
              "about:srcdoc",
              "ftp://example.com/file",
          ])
    func localAndInternalSchemesAreRefused(_ raw: String) throws {
        let url = try #require(URL(string: raw))
        #expect(BrowserReplDomainPolicy().popupBlockReason(url, allowlist: open) != nil, "\(raw) would open")
        #expect(try policy(allowed: ["*"]).popupBlockReason(url, allowlist: open) != nil, "\(raw) would open under allowedDomains *")
    }

    @Test("Web pages open unless the creating session's policy or the URL allowlist blocks them")
    func webPagesFollowThePolicyAndAllowlist() throws {
        let page = try #require(URL(string: "https://docs.example.com/a"))
        #expect(BrowserReplDomainPolicy().popupBlockReason(page, allowlist: open) == nil)
        #expect(BrowserReplDomainPolicy().popupBlockReason(URL(string: "about:blank"), allowlist: open) == nil)
        #expect(BrowserReplDomainPolicy().popupBlockReason(nil, allowlist: open) == nil)
        let prohibiting = try policy(prohibited: ["docs.example.com"])
        #expect(prohibiting.popupBlockReason(page, allowlist: open) != nil)
        let allowing = try policy(allowed: ["example.org"])
        #expect(allowing.popupBlockReason(page, allowlist: open) != nil)
        #expect(allowing.popupBlockReason(URL(string: "https://example.org/x"), allowlist: open) == nil)
        let managed = BrowserURLAllowlistPolicy(managedPatterns: ["example.org"])
        #expect(BrowserReplDomainPolicy().popupBlockReason(page, allowlist: managed) != nil)
    }

    @Test("A blob: window opens only for an origin the policy allows")
    func blobURLsFollowTheirOrigin() throws {
        let blob = try #require(URL(string: "blob:https://docs.example.com/6f1c"))
        #expect(BrowserReplDomainPolicy().popupBlockReason(blob, allowlist: open) == nil)
        #expect(try policy(prohibited: ["docs.example.com"]).popupBlockReason(blob, allowlist: open) != nil)
        #expect(BrowserReplDomainPolicy().popupBlockReason(URL(string: "blob:null/6f1c"), allowlist: open) != nil)
    }
}

/// Where a page-opened window goes depends on who owns the opener tab: only
/// a tab a session created hands its popups to the sessions. A user's tab
/// that a session drives (`tabs.use`) keeps its popups, so a session never
/// adopts, and at its end closes, a window the user's page opened.
@Suite("Browser REPL popup routing")
struct BrowserReplPopupRouteTests {
    private let open = BrowserURLAllowlistPolicy(managedPatterns: nil)

    @Test("A popup of a user's tab goes to the browser, whatever its URL",
          arguments: ["https://docs.example.com/a", "about:blank", "file:///etc/passwd"])
    func userTabPopupsStayWithTheBrowser(_ raw: String) throws {
        let route = BrowserReplPopupRoute(
            url: URL(string: raw),
            openerCreatedBySession: false,
            creatorPolicy: BrowserReplDomainPolicy(),
            allowlist: open
        )
        #expect(route == .browser, "\(raw) from a user's tab went to \(route)")
    }

    @Test("A popup of a session's tab goes to the session when allowed, and nowhere otherwise")
    func sessionTabPopupsFollowThePolicy() throws {
        var prohibiting = BrowserReplDomainPolicy()
        prohibiting.prohibited = [try BrowserReplDomainPattern.parse("evil.example", title: "t")]
        let allowed = BrowserReplPopupRoute(
            url: URL(string: "https://docs.example.com/a"),
            openerCreatedBySession: true,
            creatorPolicy: prohibiting,
            allowlist: open
        )
        #expect(allowed == .session)
        let blocked = BrowserReplPopupRoute(
            url: URL(string: "https://evil.example/a"),
            openerCreatedBySession: true,
            creatorPolicy: prohibiting,
            allowlist: open
        )
        guard case .refused = blocked else {
            Issue.record("a blocked popup of a session's tab went to \(blocked)")
            return
        }
        let local = BrowserReplPopupRoute(
            url: URL(string: "file:///etc/passwd"),
            openerCreatedBySession: true,
            creatorPolicy: BrowserReplDomainPolicy(),
            allowlist: open
        )
        guard case .refused = local else {
            Issue.record("a local file popup of a session's tab went to \(local)")
            return
        }
    }

    // An agent's click in a user's tab that opens a window must not put a
    // key popup window over the user's work (BrowserPopupWindowController
    // makes it key), and the agent could not reach it. While the session's
    // input runs, the window opens as a background tab for that session and
    // stays the user's.
    @Test("A popup the session's own input opens in a user's tab goes to that session")
    func userTabPopupsFromTheSessionsInputGoToIt() throws {
        let route = BrowserReplPopupRoute(
            url: URL(string: "https://docs.example.com/a"),
            openerCreatedBySession: false,
            creatorPolicy: BrowserReplDomainPolicy(),
            inputSession: (id: "agent", policy: BrowserReplDomainPolicy()),
            allowlist: open
        )
        #expect(route == .inputSession("agent"))
        var prohibiting = BrowserReplDomainPolicy()
        prohibiting.prohibited = [try BrowserReplDomainPattern.parse("evil.example", title: "t")]
        let blocked = BrowserReplPopupRoute(
            url: URL(string: "https://evil.example/a"),
            openerCreatedBySession: false,
            creatorPolicy: BrowserReplDomainPolicy(),
            inputSession: (id: "agent", policy: prohibiting),
            allowlist: open
        )
        guard case .refused = blocked else {
            Issue.record("a popup the session's policy blocks went to \(blocked)")
            return
        }
        let local = BrowserReplPopupRoute(
            url: URL(string: "file:///etc/passwd"),
            openerCreatedBySession: false,
            creatorPolicy: BrowserReplDomainPolicy(),
            inputSession: (id: "agent", policy: BrowserReplDomainPolicy()),
            allowlist: open
        )
        guard case .refused = local else {
            Issue.record("a local file popup went to \(local)")
            return
        }
        // Without the session's input the user's page keeps its windows.
        let own = BrowserReplPopupRoute(
            url: URL(string: "https://docs.example.com/a"),
            openerCreatedBySession: false,
            creatorPolicy: BrowserReplDomainPolicy(),
            inputSession: nil,
            allowlist: open
        )
        #expect(own == .browser)
    }
}
