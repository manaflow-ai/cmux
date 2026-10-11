import CmuxNextActions
import CmuxNextDesign
@testable import CmuxNextSettings
import Foundation
import Testing

/// The update from classic cmux (hq#1870 parity audit, P1 6): classic sent a
/// clicked terminal link to the default browser when its Settings said so,
/// from `browser.openTerminalLinksInCmuxBrowser`, `.hostsToOpenInEmbeddedBrowser`
/// and `.urlsToAlwaysOpenExternally`. Next reads the same keys from the adopted
/// `cmux.json`, and imports once what classic's Settings window kept in its
/// preferences.
@MainActor @Suite(.serialized) struct ClassicTerminalLinkRoutingTests {
    static func settings(_ json: String) throws -> (SettingsController, URL) {
        let home = FileManager.default.temporaryDirectory.appending(path: "cn-classic-links-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let url = home.appending(path: "cmux-next.json")
        try Data(json.utf8).write(to: url)
        let settings = SettingsController(registry: .standard(), design: DesignSettings(), fileURL: url,
                                          managedReader: FixedManagedPreferenceReader(ManagedPreferences()),
                                          managedWatchFiles: [])
        return (settings, home)
    }

    static func opensInCmux(_ settings: SettingsController, _ link: String) throws -> Bool {
        settings.snapshot.terminalLinkRouting.opensInCmux(try #require(URL(string: link)))
    }

    @Test func classicCmuxJSONRoutesTerminalLinks() async throws {
        let (settings, home) = try Self.settings("""
        { "browser": {
            "hostsToOpenInEmbeddedBrowser": ["*.example.com", "localhost"],
            "urlsToAlwaysOpenExternally": ["billing", "re:^https://docs\\\\.example\\\\.com/private/"]
        } }
        """)
        defer { try? FileManager.default.removeItem(at: home) }
        await settings.reload()

        #expect(try Self.opensInCmux(settings, "https://app.example.com/home"))
        #expect(try Self.opensInCmux(settings, "https://example.com/"))
        #expect(try Self.opensInCmux(settings, "http://localhost:3000/"))
        // Outside the host list.
        #expect(try !Self.opensInCmux(settings, "https://github.com/manaflow-ai"))
        // A plain rule matches anywhere in the URL, a re: rule as a regex.
        #expect(try !Self.opensInCmux(settings, "https://app.example.com/billing/usage"))
        #expect(try !Self.opensInCmux(settings, "https://docs.example.com/private/keys"))
        #expect(try Self.opensInCmux(settings, "https://docs.example.com/public/"))
        #expect(settings.snapshot.diagnostics.isEmpty)
    }

    @Test func classicPreferencesComeOverOnceOnTheUpdate() async throws {
        let (settings, home) = try Self.settings("{}")
        defer { try? FileManager.default.removeItem(at: home) }
        let name = "cn-classic-links-\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: name) }
        let defaults = try #require(UserDefaults(suiteName: name))
        // As classic's Settings window stored them: line text, one array from an older release.
        defaults.set("*.corp.example\n\n  intranet.local  ", forKey: "browserHostWhitelist")
        defaults.set(["*zoom.us*", "# a comment"], forKey: "browserExternalOpenPatterns")
        await settings.reload()

        #expect(try await settings.importClassicPreferences(from: defaults))
        #expect(try Self.opensInCmux(settings, "https://wiki.corp.example/page"))
        #expect(try Self.opensInCmux(settings, "http://intranet.local/"))
        #expect(try !Self.opensInCmux(settings, "https://example.org/"))
        #expect(try !Self.opensInCmux(settings, "https://wiki.corp.example/?join=https://zoom.us/j/1"))

        // Removed in next, then the next launch: the classic value does not come back,
        // and turning terminal links off in classic later isn't read either.
        try await settings.setSetting(at: TerminalLinkRouting.hostsPath, to: nil, by: .user)
        defaults.set(false, forKey: "browserOpenTerminalLinksInCmuxBrowser")
        #expect(try await !settings.importClassicPreferences(from: defaults))
        #expect(try Self.opensInCmux(settings, "https://example.org/"))
    }

    @Test func classicLinksOffSendsEveryLinkOut() async throws {
        let (settings, home) = try Self.settings("{}")
        defer { try? FileManager.default.removeItem(at: home) }
        let name = "cn-classic-links-\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: name) }
        let defaults = try #require(UserDefaults(suiteName: name))
        defaults.set(false, forKey: "browserOpenTerminalLinksInCmuxBrowser")
        await settings.reload()

        #expect(try await settings.importClassicPreferences(from: defaults))
        #expect(try !Self.opensInCmux(settings, "https://example.com/"))
    }
}
