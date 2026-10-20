@testable import CmuxNextSettings
import Foundation
import Testing

/// `browser.siteEngines`: which engine a site opens in, whatever `browser.defaultEngine` says.
struct BrowserSiteEnginesTests {
    private func engine(_ rules: BrowserSiteEngines, _ address: String) -> BrowserDefaultEngine? {
        rules.engine(for: URL(string: address))
    }

    @Test(arguments: [
        "https://open.spotify.com/track/1", "https://spotify.com/", "https://www.netflix.com/browse",
        "https://www.disneyplus.com/", "https://play.max.com/", "https://www.hulu.com/hub/home",
        "https://www.primevideo.com/", "https://www.amazon.com/gp/video/detail/B0", "https://tv.apple.com/",
        "https://music.apple.com/us/browse",
    ])
    func protectedMediaSitesOpenInWebKitByDefault(_ address: String) {
        #expect(engine(.fallback, address) == .webkit)
    }

    @Test(arguments: [
        "https://music.youtube.com/", "https://www.amazon.com/", "https://www.amazon.com/gp/videos", "https://apple.com/",
        "https://notspotify.com/", "https://spotify.com.evil.example/", "file:///tmp/spotify.com", "cmux://spotify.com",
        "https://example.com/?u=spotify.com",
    ])
    func otherSitesFollowTheDefaultEngine(_ address: String) {
        #expect(engine(.fallback, address) == nil)
    }

    @Test func theMostSpecificRuleWins() {
        let rules = BrowserSiteEngines(rules: ["example.com": .webkit, "app.example.com": .chromium,
                                               "example.com/docs": .chromium, "example.com/docs/old": .webkit])
        #expect(engine(rules, "https://www.example.com/") == .webkit)
        #expect(engine(rules, "https://app.example.com/docs") == .chromium)
        #expect(engine(rules, "https://example.com/docs/new") == .chromium)
        #expect(engine(rules, "https://example.com/docs/old/a") == .webkit)
        #expect(engine(rules, "https://example.com/docsx") == .webkit)
    }

    @Test func patternsAreNormalized() {
        let rules = BrowserSiteEngines(rules: ["HTTPS://*.Open.Spotify.COM/": .webkit, "  ": .chromium, "/path": .chromium])
        #expect(rules.rules == ["open.spotify.com": .webkit])
        #expect(engine(rules, "https://OPEN.spotify.com./x") == .webkit)
    }

    @Test func theSettingReplacesTheDefaultList() {
        let root = JSONValue.object(["browser": .object(["siteEngines": .object([
            "netflix.com": .string("chromium"), "example.com": .string("webkit"), "bad.example": .string("gecko"),
        ])])])
        let (rules, diagnostics) = BrowserSiteEngines.parse(root)
        #expect(rules.rules == ["netflix.com": .chromium, "example.com": .webkit])
        #expect(engine(rules, "https://open.spotify.com/") == nil)
        #expect(diagnostics.count == 1)
        #expect(diagnostics.first?.path == "browser.siteEngines")
    }

    @Test func aMissingOrBrokenSettingKeepsTheDefaults() {
        #expect(BrowserSiteEngines.parse(.object([:])).0 == .fallback)
        let (rules, diagnostics) = BrowserSiteEngines.parse(.object(["browser": .object(["siteEngines": .array([])])]))
        #expect(rules == .fallback)
        #expect(diagnostics.count == 1)
        #expect(BrowserSiteEngines.parse(.object(["browser": .object(["siteEngines": .object([:])])])).0.rules.isEmpty)
    }

    @Test func theDefaultIsWhatTheSchemaWritesToTheFile() {
        let (rules, _) = BrowserSiteEngines.parse(.object(["browser": .object(["siteEngines": BrowserSiteEngines.fallback.jsonValue])]))
        #expect(rules == .fallback)
    }

    /// The cases the daemon's matcher (cmux-tui-core `browser_site_engines`) runs too, so the app
    /// and the daemon pick the same engine for a URL.
    @Test func theSharedCasesMatchTheDaemon() throws {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "cmux-tui/crates/cmux-tui-core/tests/fixtures/browser_site_engines.json")
        let fixture = try JSONValue.parse(Data(contentsOf: file))
        let defaults = try #require(fixture["defaults"])
        #expect(BrowserSiteEngines.fallback.jsonValue == defaults)
        guard case .array(let suites)? = fixture["suites"] else { throw FixtureError.shape }
        for suite in suites {
            let rules: BrowserSiteEngines
            if suite["rules"]?.stringValue == "defaults" {
                rules = .fallback
            } else {
                rules = BrowserSiteEngines.parse(.object(["browser": .object(["siteEngines": try #require(suite["rules"])])])).0
            }
            guard case .array(let cases)? = suite["cases"] else { throw FixtureError.shape }
            for item in cases {
                guard case .array(let pair) = item, pair.count == 2, let address = pair[0].stringValue else { throw FixtureError.shape }
                let expected = pair[1].stringValue.flatMap(BrowserDefaultEngine.init(rawValue:))
                #expect(rules.engine(for: URL(string: address)) == expected, "\(address)")
            }
        }
    }

    private enum FixtureError: Error { case shape }
}
