@testable import CmuxNextSettings
import Testing

/// `browser.pageShortcuts` (CMUX-641): `ask` unless cmux.json says `page` or `cmux`.
struct BrowserPageShortcutsSettingTests {
    private static func snapshot(_ root: JSONValue) -> CmuxConfigSnapshot {
        CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: [])
    }

    @Test func askWhenUnset() {
        #expect(Self.snapshot(.object([:])).browserPageShortcuts == .ask)
        #expect(Self.snapshot(.object(["browser": .object([:])])).browserPageShortcuts == .ask)
    }

    @Test(arguments: [BrowserPageShortcuts.page, .cmux, .ask]) func readsEachChoice(_ mode: BrowserPageShortcuts) {
        let parsed = Self.snapshot(.object(["browser": .object(["pageShortcuts": .string(mode.rawValue)])]))
        #expect(parsed.browserPageShortcuts == mode)
        #expect(parsed.diagnostics.isEmpty)
    }

    @Test func anUnknownValueIsAskWithADiagnostic() {
        let bad = Self.snapshot(.object(["browser": .object(["pageShortcuts": .string("website")])]))
        #expect(bad.browserPageShortcuts == .ask)
        #expect(bad.diagnostics.contains { $0.path == "browser.pageShortcuts" })
    }

    @Test func theSettingsPageListsIt() throws {
        let descriptor = try #require(SettingsSchema.descriptor(for: ["browser", "pageShortcuts"]))
        #expect(descriptor.defaultValue == .string("ask"))
        #expect(descriptor.isPaletteExposed)
    }

    /// `browser.pageShortcutSites` (Lucas 2026-11-18: ask per web page): a site's answer wins, its subdomains share it,
    /// and a site with no entry follows `browser.pageShortcuts`.
    @Test func aSiteAnswerWinsOverTheDefault() {
        let parsed = Self.snapshot(.object(["browser": .object([
            "pageShortcuts": .string("cmux"),
            "pageShortcutSites": .object(["linear.app": .string("page"), "docs.example.com": .string("cmux"), "example.com": .string("page")]),
        ])]))
        #expect(parsed.diagnostics.isEmpty)
        #expect(parsed.pageShortcuts(forHost: "linear.app") == .page)
        #expect(parsed.pageShortcuts(forHost: "www.linear.app") == .page)
        #expect(parsed.pageShortcuts(forHost: "docs.example.com") == .cmux, "the longer site did not win")
        #expect(parsed.pageShortcuts(forHost: "mail.example.com") == .page)
        #expect(parsed.pageShortcuts(forHost: "notlinear.app") == .cmux, "a name ending in the site matched it")
        #expect(parsed.pageShortcuts(forHost: nil) == .cmux)
    }

    @Test func aBadSiteEntryIsLeftOutWithADiagnostic() {
        let parsed = Self.snapshot(.object(["browser": .object([
            "pageShortcutSites": .object(["linear.app": .string("ask"), "a b": .string("page"), "github.com": .string("page")]),
        ])]))
        #expect(parsed.browserPageShortcutSites.rules == ["github.com": .page])
        #expect(parsed.diagnostics.filter { $0.path == "browser.pageShortcutSites" }.count == 2)
    }

    /// `www.example.com` keeps its own answer beside `example.com` (review: both became `example.com`).
    @Test func wwwKeepsItsOwnAnswer() {
        let sites = BrowserPageShortcutSites(rules: ["example.com": .cmux, "www.example.com": .page])
        #expect(sites.mode(forHost: "www.example.com") == .page)
        #expect(sites.mode(forHost: "example.com") == .cmux)
        #expect(sites.mode(forHost: "a.www.example.com") == .page)
    }

    /// The dialog's answer for one site adds it to the others.
    @Test func anAnswerAddsItsSite() {
        let sites = BrowserPageShortcutSites(rules: ["github.com": .cmux])
        #expect(sites.setting(.page, forHost: "www.Linear.app") == .object(["github.com": .string("cmux"), "linear.app": .string("page")]))
    }

    @Test func theSettingsPageListsTheSites() throws {
        let descriptor = try #require(SettingsSchema.descriptor(for: ["browser", "pageShortcutSites"]))
        #expect(descriptor.defaultValue == .object([:]))
        #expect(descriptor.isPaletteExposed)
    }
}
