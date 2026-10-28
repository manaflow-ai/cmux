import CmuxNextActions
import CmuxNextAppearance
@testable import CmuxNextSettings
import Foundation
import Testing

/// The organization's Chrome policies reach cmux with no extra setup
/// (plans/cmux-next/chrome-enterprise-policy-DESIGN.md): a company that
/// already deploys `com.google.Chrome` policies gets the same default search,
/// new tab page, password manager switch, URL blocklist and force-installed
/// extensions in cmux, and Settings shows those rows as managed.
@MainActor @Suite(.serialized) struct ChromeEnterprisePolicyTests {
    /// Tests/CmuxNextSettingsTests/<file> -> Tests/Fixtures/chrome-policy/<name>.
    static func fixture(_ name: String) -> URL {
        var url = URL(fileURLWithPath: #filePath)
        url.deleteLastPathComponent()
        url.deleteLastPathComponent()
        return url.appending(path: "Fixtures/chrome-policy/\(name)")
    }

    static func settings(_ json: String = "{}", cmux: ManagedPreferences = .empty, chrome: any ChromePolicyReading,
                         cmuxBrowser: ChromePolicyDocument = .empty) throws -> (SettingsController, URL) {
        let home = FileManager.default.temporaryDirectory.appending(path: "cn-chrome-policy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let url = home.appending(path: "cmux-next.json")
        try Data(json.utf8).write(to: url)
        let reader = ChromePolicyManagedPreferenceReader(cmux: FixedManagedPreferenceReader(cmux), chrome: chrome,
                                                         cmuxBrowser: FixedChromePolicyReader(cmuxBrowser))
        let settings = SettingsController(registry: .standard(), design: DesignSettings(), fileURL: url,
                                          managedReader: reader, managedWatchFiles: [])
        return (settings, home)
    }

    @Test func fixturePlistsReadAsChromeReadsThem() throws {
        let mandatory = PlistChromePolicyReader(url: Self.fixture("chrome-mandatory.plist")).read()
        #expect(mandatory.mandatory["URLBlocklist"] == .array(["facebook.com", "example.org/private", "file://*"]))
        #expect(mandatory.recommended.isEmpty)
        let recommended = PlistChromePolicyReader(url: Self.fixture("chrome-recommended.plist")).read()
        #expect(recommended.mandatory.isEmpty)
        #expect(recommended.recommended["DefaultSearchProviderSearchURL"] == "https://search.example.com/search?q={searchTerms}")
    }

    /// Mandatory Chrome policies lock the matching cmux settings over the person's own file.
    @Test func mandatoryChromePoliciesBecomeManagedSettings() async throws {
        let (settings, home) = try Self.settings(#"{ "browser": { "searchEngine": "duckduckgo" } }"#,
                                                 chrome: PlistChromePolicyReader(url: Self.fixture("chrome-mandatory.plist")))
        defer { try? FileManager.default.removeItem(at: home) }
        await settings.reload()

        let omnibar = settings.snapshot.browserOmnibar
        #expect(omnibar.searchEngine == "custom")
        #expect(omnibar.customSearch == "https://search.example.com/search?q={searchTerms}")
        #expect(omnibar.customSuggest == "https://search.example.com/suggest?q={searchTerms}")
        #expect(settings.snapshot.browserNewTabPage == URL(string: "https://intranet.example.com/start"))
        let passwords = BrowserPasswordsSetting.current(settings)
        #expect(!passwords.offerToSave)
        #expect(!passwords.generate)
        // Settings shows "Managed by your organization" for these rows.
        #expect(settings.managedKeys["browser.searchEngine"] == .device)
        #expect(settings.managedKeys["browser.customSearchEngine.search"] == .device)
        #expect(settings.managedKeys["browser.newTabPage"] == .device)
        #expect(settings.diagnostics.contains { $0.kind == .managedOverride && $0.path == "browser.searchEngine" })
        // Enforced policies the browser reads by their Chrome names.
        #expect(settings.managedPolicy["URLBlocklist"] == .array(["facebook.com", "example.org/private", "file://*"]))
        #expect(settings.managedPolicy["URLAllowlist"] == .array(["example.org/private/handbook"]))
        #expect(settings.managedPolicy["ExtensionInstallForcelist"] == .array([
            "aeblfdkhhhdcdjpifhhbdiojplfjncoa;https://clients2.google.com/service/update2/crx", "ppnbnpeolgkicgegkbkbjmhlideopiji",
        ]))
        // Policies Chromium reads natively are not cmux settings.
        #expect(settings.managedPolicy["AuthServerAllowlist"] == nil)
    }

    /// Recommended Chrome policies only replace defaults; Chrome never reads a recommended URLBlocklist.
    @Test func recommendedChromePoliciesOnlyFillDefaults() async throws {
        let chrome = PlistChromePolicyReader(url: Self.fixture("chrome-recommended.plist"))
        let (mine, mineHome) = try Self.settings(#"{ "browser": { "searchEngine": "duckduckgo" } }"#, chrome: chrome)
        defer { try? FileManager.default.removeItem(at: mineHome) }
        await mine.reload()
        #expect(mine.snapshot.browserOmnibar.searchEngine == "duckduckgo")
        #expect(mine.managedKeys["browser.searchEngine"] == nil)

        let (fresh, freshHome) = try Self.settings(chrome: chrome)
        defer { try? FileManager.default.removeItem(at: freshHome) }
        await fresh.reload()
        #expect(fresh.snapshot.browserOmnibar.searchEngine == "custom")
        #expect(fresh.snapshot.browserOmnibar.customSearch == "https://search.example.com/search?q={searchTerms}")
        #expect(fresh.managedPolicy["URLBlocklist"] == nil)
    }

    /// cmux's own domain wins over the browser domain, which wins over Chrome's, key by key.
    @Test func cmuxDomainsWinOverChrome() async throws {
        let (settings, home) = try Self.settings(
            cmux: ManagedPreferences(forced: ["browser.searchEngine": "kagi"]),
            chrome: PlistChromePolicyReader(url: Self.fixture("chrome-mandatory.plist")),
            cmuxBrowser: ChromePolicyDocument(mandatory: ["URLBlocklist": .array(["x.com"])]))
        defer { try? FileManager.default.removeItem(at: home) }
        await settings.reload()
        #expect(settings.snapshot.browserOmnibar.searchEngine == "kagi")
        #expect(settings.managedPolicy["URLBlocklist"] == .array(["x.com"]))
        #expect(settings.managedPolicy["URLAllowlist"] == .array(["example.org/private/handbook"]))
    }

    /// A forced HonorChromePolicy = false in cmux's browser domain drops Chrome's policies, Chromium's native read included.
    @Test func organizationCanOptOutOfChromePolicies() async throws {
        let optOut = ChromePolicyDocument(mandatory: ["HonorChromePolicy": .bool(false), "URLBlocklist": .array(["x.com"])])
        let (settings, home) = try Self.settings(chrome: PlistChromePolicyReader(url: Self.fixture("chrome-mandatory.plist")),
                                                 cmuxBrowser: optOut)
        defer { try? FileManager.default.removeItem(at: home) }
        await settings.reload()
        #expect(settings.snapshot.browserOmnibar.searchEngine != "custom")
        #expect(settings.managedPolicy["URLBlocklist"] == .array(["x.com"]))
        #expect(settings.managedPolicy["HonorChromePolicy"] == nil)
        #expect(ChromePolicyDocument.nativePolicyDomain(cmuxBrowser: optOut) == nil)
        #expect(ChromePolicyDocument.nativePolicyDomain(cmuxBrowser: .empty) == "com.google.Chrome")
    }

    /// A search address Chrome could not use either (no {searchTerms}, not http) changes nothing.
    @Test func unusableSearchPolicyIsIgnored() {
        for search in ["https://search.example.com/?q=", "javascript:alert({searchTerms})"] {
            let managed = ManagedPreferences(chromePolicy: ChromePolicyDocument(mandatory: ["DefaultSearchProviderSearchURL": .string(search)]))
            #expect(managed.forced["browser.searchEngine"] == nil, "\(search)")
        }
        let disabled = ManagedPreferences(chromePolicy: ChromePolicyDocument(mandatory: [
            "DefaultSearchProviderEnabled": .bool(false), "DefaultSearchProviderSearchURL": "https://s.example.com/?q={searchTerms}",
        ]))
        #expect(disabled.forced["browser.searchEngine"] == nil)
    }
}
