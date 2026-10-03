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
