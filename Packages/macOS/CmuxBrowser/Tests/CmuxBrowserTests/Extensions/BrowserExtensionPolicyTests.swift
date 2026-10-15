import CryptoKit
import Foundation
import Testing
@testable import CmuxBrowser

@Suite("Browser extension policies")
struct BrowserExtensionPolicyTests {
    // MARK: Automation policy

    @Test
    func automationNeedsConsentForAnythingThatAddsReach() {
        let policy = BrowserExtensionAutomationPolicy()
        for operation in [BrowserExtensionOperation.loadUnpacked, .enable, .run, .command, .options, .openManagement] {
            #expect(policy.decision(for: operation) == .requiresConsent, "\(operation)")
        }
        for operation in [BrowserExtensionOperation.list, .disable, .remove, .reload, .pin, .unpin, .move,
                          .openWebStore] {
            #expect(policy.decision(for: operation) == .allow, "\(operation)")
        }
        #expect(policy.decision(for: .installPacked) == .deny)
    }

    @Test
    func reloadingAnExtensionThePersonTurnedOffNeedsConsent() {
        let policy = BrowserExtensionAutomationPolicy()
        let off = BrowserExtensionInfo(id: "x", name: "x", isEnabled: false)
        let crashed = BrowserExtensionInfo(id: "x", name: "x", isEnabled: false, isTerminated: true)
        let running = BrowserExtensionInfo(id: "x", name: "x")
        #expect(policy.decision(for: .reload, target: off) == .requiresConsent)
        #expect(policy.decision(for: .reload, target: crashed) == .allow)
        #expect(policy.decision(for: .reload, target: running) == .allow)
        let unpacked = BrowserExtensionInfo(id: "x", name: "x", location: .unpacked)
        #expect(policy.decision(for: .reload, target: unpacked) == .requiresConsent, "re-reads a folder that may have changed")
        #expect(policy.decision(for: .disable, target: unpacked) == .allow)
        #expect(policy.decision(for: .enable, target: running) == .requiresConsent)
    }

    // MARK: Agent access

    private func access(_ manifests: [String: [String: Any]], trusted: String? = nil) -> BrowserExtensionAgentAccess {
        BrowserExtensionAgentAccess(trustedBuiltInFolder: trusted) { manifests[$0] }
    }

    @Test
    func blockersCountHostPermissionsContentScriptsAndFailClosed() throws {
        let page = try #require(URL(string: "https://mail.example.com/inbox"))
        let rule = access([
            "/hosts": ["host_permissions": ["https://*.example.com/*"]],
            "/scripts": ["content_scripts": [["matches": ["*://mail.example.com/*"]]]],
            "/mv2": ["permissions": ["tabs", "<all_urls>"]],
            "/other": ["host_permissions": ["https://other.test/*"]],
            "/active": ["permissions": ["activeTab"]],
        ])
        let extensions = ["/hosts", "/scripts", "/mv2", "/other", "/active", "/missing"].map {
            BrowserExtensionInfo(id: $0, name: $0, path: $0)
        } + [BrowserExtensionInfo(id: "off", name: "off", isEnabled: false, path: "/hosts")]
        let blockers = rule.blockers(extensions, url: page).map(\.id)
        #expect(blockers == ["/hosts", "/scripts", "/mv2", "/missing"])
        #expect(rule.blockers(extensions, url: URL(string: "about:blank")).isEmpty)
        #expect(rule.blockers(extensions, url: nil).isEmpty)
    }

    @Test(arguments: [
        ("https://*.example.com/*", "https://example.com/", true),
        ("https://*.example.com/*", "https://evil-example.com/", false),
        ("*://a.test/*", "http://a.test/x", true),
        ("*://a.test/*", "ftp://a.test/x", false),
        ("http://a.test:8080/*", "http://a.test:8080/", true),
        ("http://a.test:8080/*", "http://a.test/", false),
        ("http://a.test:*/*", "http://a.test:9/", true),
        ("https://a.test/*", "http://a.test/", false),
        ("file:///*", "file:///etc/hosts", true),
        ("chrome://*/*", "https://a.test/", false),
        ("garbage", "https://a.test/", true),
        ("https://a*.test/*", "https://b.test/", true),
    ])
    func matchPatterns(_ pattern: String, _ page: String, _ expected: Bool) throws {
        let url = try #require(URL(string: page))
        #expect(access([:]).matches(pattern, url) == expected)
    }

    @Test
    func trustedBuiltInDoesNotCountButAPersonCopyDoes() throws {
        let page = try #require(URL(string: "https://a.test/"))
        let folder = "/Apps/cmux.app/Contents/Resources/Extensions/ublock-origin"
        let rule = access([folder: ["host_permissions": ["<all_urls>"]], "/mine": ["host_permissions": ["<all_urls>"]]],
                          trusted: folder)
        let builtIn = BrowserExtensionInfo(id: BrowserBuiltInExtensions.adBlockerID, name: "uBO", path: folder)
        let mine = BrowserExtensionInfo(id: BrowserBuiltInExtensions.adBlockerID, name: "uBO", path: "/mine")
        #expect(rule.blockers([builtIn], url: page).isEmpty)
        #expect(rule.blockers([mine], url: page).count == 1)
        #expect(access([folder: [:]]).blockers([builtIn], url: page).isEmpty, "empty manifest has no hosts")
        let untrusted = access([folder: ["host_permissions": ["<all_urls>"]]])
        #expect(untrusted.blockers([builtIn], url: page).count == 1)
    }

    // MARK: Built-ins

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ext-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test
    func builtInPlanLoadsOnlyWhenOnAndBundled() {
        let resources = URL(fileURLWithPath: "/Apps/cmux.app/Contents/Resources")
        let folder = resources.appendingPathComponent(BrowserBuiltInExtensions.adBlockerFolder).path
        let on = BrowserBuiltInExtensions(adBlockerEnabled: true)
        #expect(on.plan(resources: resources, profiles: nil) { _ in true }
            == .init(folders: [folder], keepsUnpackedEnabled: true))
        #expect(on.plan(resources: resources, profiles: nil) { _ in false }.folders.isEmpty)
        #expect(BrowserBuiltInExtensions(adBlockerEnabled: false).plan(resources: resources, profiles: nil) { _ in true }
            .folders.isEmpty)
        let comma = URL(fileURLWithPath: "/Apps/a,b.app/Contents/Resources")
        #expect(on.plan(resources: comma, profiles: nil) { _ in true }.folders.isEmpty)
    }

    @Test
    func personInstalledCopyWins() throws {
        let profiles = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: profiles) }
        let profile = profiles.appendingPathComponent("Profile-1")
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        let id = BrowserBuiltInExtensions.adBlockerID
        func write(path: String, location: Int) throws {
            let prefs: [String: Any] = ["extensions": ["settings": [id: ["path": path, "location": location]]]]
            try JSONSerialization.data(withJSONObject: prefs).write(to: profile.appendingPathComponent("Secure Preferences"))
        }
        try write(path: "/Old/cmux.app/Contents/Resources/Extensions/ublock-origin", location: 8)
        #expect(BrowserBuiltInExtensions.personAdBlockerLocation(profiles: profiles) == nil)
        try write(path: "\(id)/1.0_0", location: 1)
        #expect(BrowserBuiltInExtensions.personAdBlockerLocation(profiles: profiles) == 1)
        let resources = URL(fileURLWithPath: "/Apps/cmux.app/Contents/Resources")
        #expect(BrowserBuiltInExtensions(adBlockerEnabled: true).plan(resources: resources, profiles: profiles) { _ in true }
            == .init(folders: [], keepsUnpackedEnabled: false))
        try write(path: "/Users/me/ublock", location: 4)
        #expect(BrowserBuiltInExtensions(adBlockerEnabled: true).plan(resources: resources, profiles: profiles) { _ in true }
            == .init(folders: [], keepsUnpackedEnabled: true))
    }

    @Test
    func trustNeedsThePinnedManifestHash() throws {
        let resources = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: resources) }
        let manifest = Data("{\"name\":\"uBO\"}".utf8)
        let hash = SHA256.hash(data: manifest).map { String(format: "%02x", $0) }.joined()
        let folder = resources.appendingPathComponent(BrowserBuiltInExtensions.adBlockerFolder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try manifest.write(to: folder.appendingPathComponent("manifest.json"))
        let expected = folder.resolvingSymlinksInPath().standardizedFileURL.path
        #expect(BrowserBuiltInExtensionTrust(resources: resources, expectedSHA256: hash).trustedAdBlockerFolder == expected)
        #expect(BrowserBuiltInExtensionTrust(resources: resources).trustedAdBlockerFolder == nil)
        #expect(BrowserBuiltInExtensionTrust(resources: nil).trustedAdBlockerFolder == nil)
    }
}
