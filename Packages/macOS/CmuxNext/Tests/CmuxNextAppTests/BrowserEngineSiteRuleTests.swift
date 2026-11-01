@testable import CmuxNextApp
import CmuxNextBrowser
import CmuxNextBrowserTabs
import CmuxNextSettings
import Foundation
import Testing

/// u2320: a protected-media site (Spotify, Netflix) opens in WebKit through `browser.siteEngines`,
/// whatever `browser.defaultEngine` says; an explicit `--engine` still wins, and a reopened tab
/// keeps its record's engine.
@Suite struct BrowserEngineSiteRuleTests {
    private func choice(_ outcome: BrowserEngineResolver.Outcome) throws -> BrowserEngineChoice {
        guard case .open(let choice) = outcome else {
            Issue.record("refused: \(outcome)")
            throw CancellationError()
        }
        return choice
    }

    private func siteEngine(_ url: String) -> BrowserDefaultEngine? {
        BrowserSiteEngines.fallback.engine(for: URL(string: url))
    }

    @Test(arguments: [
        "https://open.spotify.com/track/1", "https://www.netflix.com/browse", "https://www.disneyplus.com/",
        "https://play.max.com/", "https://www.hulu.com/hub/home", "https://www.primevideo.com/",
        "https://www.amazon.com/gp/video/storefront", "https://tv.apple.com/", "https://music.apple.com/us/browse",
    ])
    func aProtectedMediaSiteOpensInWebKitAndIsPinned(url: String) throws {
        let opened = try choice(BrowserEngineResolver(defaultEngine: .chromium, cefUnavailable: nil)
            .resolve(requested: nil, siteEngine: siteEngine(url)))
        #expect(opened.engine == .webkit)
        #expect(opened.pinned)
        #expect(opened.fallback == nil)
    }

    @Test(arguments: ["https://music.youtube.com/", "https://www.amazon.com/dp/B000", "https://example.com/"])
    func anotherSiteFollowsTheDefaultEngine(url: String) throws {
        let opened = try choice(BrowserEngineResolver(defaultEngine: .chromium, cefUnavailable: nil)
            .resolve(requested: nil, siteEngine: siteEngine(url)))
        #expect(opened.engine == .cef)
        #expect(!opened.pinned)
    }

    @Test func anExplicitEngineBeatsTheSiteRule() throws {
        let opened = try choice(BrowserEngineResolver(defaultEngine: .chromium, cefUnavailable: nil)
            .resolve(requested: "chromium", siteEngine: .webkit))
        #expect(opened.engine == .cef)
        #expect(opened.pinned)
    }

    @Test func anInheritedEngineBeatsTheSiteRule() throws {
        let opened = try choice(BrowserEngineResolver(defaultEngine: .webkit, cefUnavailable: nil)
            .resolve(requested: nil, inherited: "cef", siteEngine: .webkit))
        #expect(opened.engine == .cef)
        #expect(opened.inherited)
        #expect(!opened.pinned)
    }

    @Test func aChromiumSiteRuleFallsBackToWebKitWhenChromiumIsMissing() throws {
        let opened = try choice(BrowserEngineResolver(defaultEngine: .webkit, cefUnavailable: .notBundled)
            .resolve(requested: nil, siteEngine: .chromium))
        #expect(opened.engine == .webkit)
        #expect(opened.fallback == .notBundled)
    }

    @Test func aChromiumSiteRuleBeatsAWebKitDefault() throws {
        let opened = try choice(BrowserEngineResolver(defaultEngine: .webkit, cefUnavailable: nil)
            .resolve(requested: nil, siteEngine: .chromium))
        #expect(opened.engine == .cef)
        #expect(opened.pinned)
    }
}
