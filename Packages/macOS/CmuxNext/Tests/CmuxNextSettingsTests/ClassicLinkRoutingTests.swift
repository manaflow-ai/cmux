import CmuxNextActions
import CmuxNextAppearance
@testable import CmuxNextSettings
import Foundation
import Testing

/// The update from classic cmux (hq#1870 parity audit, P1 6): classic sent a
/// clicked terminal link to the default browser when its Settings said so,
/// from `browser.openTerminalLinksInCmuxBrowser`, `.hostsToOpenInEmbeddedBrowser`
/// and `.urlsToAlwaysOpenExternally`. Next reads the same keys from the adopted
/// `cmux.json`, and imports once what classic's Settings window kept in its
/// preferences.
@MainActor @Suite(.serialized) struct ClassicLinkRoutingTests {
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
        settings.snapshot.linkRouting.opensInCmux(try #require(URL(string: link)))
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

    /// Two classic preference domains: this channel's (next's own defaults, the import's marker) and stable's.
    static func domains() throws -> (own: UserDefaults, stable: UserDefaults, names: [String]) {
        let names = ["own", "stable"].map { "cn-classic-links-\($0)-\(UUID().uuidString)" }
        return (try #require(UserDefaults(suiteName: names[0])), try #require(UserDefaults(suiteName: names[1])), names)
    }

    @Test func classicPreferencesComeOverOnceOnTheUpdate() async throws {
        let (settings, home) = try Self.settings("{}")
        defer { try? FileManager.default.removeItem(at: home) }
        let (own, stable, names) = try Self.domains()
        defer { names.forEach(UserDefaults().removePersistentDomain(forName:)) }
        // As classic's Settings window stored them: line text, one array from an older release.
        own.set("*.corp.example\n\n  intranet.local  ", forKey: "browserHostWhitelist")
        own.set(["*zoom.us*", "# a comment"], forKey: "browserExternalOpenPatterns")
        stable.set("stable.example", forKey: "browserHostWhitelist")
        await settings.reload()

        #expect(try await settings.importClassicPreferences(from: [own, stable], marker: own))
        #expect(try Self.opensInCmux(settings, "https://wiki.corp.example/page"))
        #expect(try Self.opensInCmux(settings, "http://intranet.local/"))
        #expect(try !Self.opensInCmux(settings, "https://example.org/"))
        #expect(try !Self.opensInCmux(settings, "https://stable.example/"))
        #expect(try !Self.opensInCmux(settings, "https://wiki.corp.example/?join=https://zoom.us/j/1"))

        // Removed in next, then the next launch: the classic value does not come back,
        // and turning terminal links off in classic later isn't read either.
        try await settings.setSetting(at: LinkRouting.hostsPath, to: nil, by: .user)
        own.set(false, forKey: "browserOpenTerminalLinksInCmuxBrowser")
        #expect(try await !settings.importClassicPreferences(from: [own, stable], marker: own))
        #expect(try Self.opensInCmux(settings, "https://example.org/"))
    }

    /// Someone who set it up in classic stable and updates on another channel keeps it.
    @Test func anotherChannelsClassicPreferencesComeOver() async throws {
        let (settings, home) = try Self.settings("{}")
        defer { try? FileManager.default.removeItem(at: home) }
        let (own, stable, names) = try Self.domains()
        defer { names.forEach(UserDefaults().removePersistentDomain(forName:)) }
        stable.set(false, forKey: "browserOpenTerminalLinksInCmuxBrowser")
        stable.set("re:^https://bank\\.example/", forKey: "browserExternalOpenPatterns")
        await settings.reload()

        #expect(try await settings.importClassicPreferences(from: [own, stable], marker: own))
        #expect(try !Self.opensInCmux(settings, "https://example.com/"))
        // Cmd-Option picks a cmux browser profile: the toggle doesn't apply, the rules do.
        let routing = settings.snapshot.linkRouting
        #expect(routing.opensInCmux(try #require(URL(string: "https://example.com/")), explicit: true))
        #expect(!routing.opensInCmux(try #require(URL(string: "https://bank.example/login")), explicit: true))
        // A link with no usable host goes out, as in classic.
        #expect(!LinkRouting.fallback.opensInCmux(try #require(URL(string: "https://")), explicit: true))
    }

    /// The keys decide which links leave a browser agents drive, so only the person changes them,
    /// and `cmux.json` takes the arrays the Settings rows write.
    @Test func agentsCannotMoveLinksIntoCmuxAndTextValuesAreRefused() async throws {
        let (settings, home) = try Self.settings("""
        { "browser": { "hostsToOpenInEmbeddedBrowser": "a.example\\nb.example" } }
        """)
        defer { try? FileManager.default.removeItem(at: home) }
        await settings.reload()
        #expect(settings.snapshot.linkRouting.embeddedHosts.isEmpty)
        #expect(settings.snapshot.diagnostics.contains { $0.path == "browser.hostsToOpenInEmbeddedBrowser" })

        for path in [LinkRouting.openPath, LinkRouting.hostsPath, LinkRouting.rulesPath] {
            await #expect(throws: SettingUserOnly.self) {
                try await settings.setSetting(at: path, to: nil, by: .caller("mcp"))
            }
        }
    }
}
