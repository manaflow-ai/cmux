import Foundation
import Testing
@testable import CmuxNextBrowser

/// Interim rule until fork P6 blocks extensions per tab: an agent may not
/// drive a page that an enabled extension of the tab's profile can reach
/// (plans/cmux-next/passwords.md, section 3.4).
@Suite struct AgentExtensionAccessTests {
    func ext(_ id: String, enabled: Bool = true) -> BrowserExtensionInfo {
        BrowserExtensionInfo(id: id, name: "Ext \(id)", isEnabled: enabled, path: "/ext/\(id)")
    }

    func access(_ manifests: [String: [String: Any]]) -> AgentExtensionAccess {
        AgentExtensionAccess { path in manifests[path] }
    }

    let page = URL(string: "https://accounts.example.com/login")!

    @Test func anAllURLsPasswordManagerBlocks() {
        let rule = access(["/ext/bw": ["manifest_version": 3, "host_permissions": ["<all_urls>"]]])
        #expect(rule.blockers([ext("bw")], url: page).map(\.id) == ["bw"])
    }

    @Test func contentScriptMatchesBlock() {
        let rule = access(["/ext/cs": ["content_scripts": [["matches": ["https://*.example.com/*"]]]]])
        #expect(rule.blockers([ext("cs")], url: page).map(\.id) == ["cs"])
        #expect(rule.blockers([ext("cs")], url: URL(string: "https://other.test/")!).isEmpty)
    }

    @Test func optionalHostPermissionsCountBecauseTheyMayBeGranted() {
        let rule = access(["/ext/o": ["optional_host_permissions": ["*://*/*"]]])
        #expect(rule.blockers([ext("o")], url: page).map(\.id) == ["o"])
    }

    @Test func manifestV2HostPermissionsInPermissionsBlock() {
        let rule = access(["/ext/v2": ["manifest_version": 2, "permissions": ["storage", "http://*/*", "https://*/*"]]])
        #expect(rule.blockers([ext("v2")], url: page).map(\.id) == ["v2"])
    }

    @Test func extensionsWithoutHostAccessAndDisabledOnesDoNotBlock() {
        let rule = access([
            "/ext/plain": ["permissions": ["storage", "activeTab"]],
            "/ext/off": ["host_permissions": ["<all_urls>"]],
        ])
        #expect(rule.blockers([ext("plain"), ext("off", enabled: false)], url: page).isEmpty)
    }

    /// Fail closed: an unreadable manifest or a pattern the rule cannot parse counts.
    @Test func unreadableManifestsAndBadPatternsBlock() {
        let rule = access(["/ext/bad": ["host_permissions": ["not a pattern"]]])
        #expect(rule.blockers([ext("gone")], url: page).map(\.id) == ["gone"])
        #expect(rule.blockers([ext("bad")], url: page).map(\.id) == ["bad"])
    }

    @Test func hostPatternsFollowChromeRules() {
        let rule = AgentExtensionAccess { _ in nil }
        #expect(rule.matches("*://*.example.com/*", page))
        #expect(rule.matches("https://accounts.example.com/*", page))
        #expect(rule.matches("*://example.com/*", URL(string: "http://example.com/x")!))
        #expect(!rule.matches("*://example.com/*", page), "no subdomains without *.")
        #expect(!rule.matches("http://*/*", page), "scheme must match")
        #expect(rule.matches("<all_urls>", page))
        #expect(rule.matches("https://accounts.example.com:8443/*", URL(string: "https://accounts.example.com:8443/a")!))
    }

    /// Pages that are not web pages (about:blank) have nothing to read yet;
    /// the target of a navigation is checked on its own.
    @Test func blankPagesHaveNoBlockers() {
        let rule = access(["/ext/bw": ["host_permissions": ["<all_urls>"]]])
        #expect(rule.blockers([ext("bw")], url: URL(string: "about:blank")!).isEmpty)
        #expect(rule.blockers([ext("bw")], url: nil).isEmpty)
    }
}
