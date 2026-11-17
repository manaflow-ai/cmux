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

    // https://github.com/manaflow-ai/cmux/issues/45018: a Chromium tab that commits a protected-media site after it
    // was made (a typed address on the New Tab page, a link, a restored record) moves to WebKit too.

    private func navigation(_ url: String, chromium: Bool = true, pinned: Bool = false, reopened: Bool = false,
                            agent: Bool = false) -> BrowserSiteEngineNavigation {
        BrowserSiteEngineNavigation(siteEngine: siteEngine(url), engineIsChromium: chromium, enginePinned: pinned,
                                    alreadyReopened: reopened, agentDriven: agent)
    }

    @Test(arguments: ["https://open.spotify.com/", "https://open.spotify.com/track/1", "https://www.netflix.com/watch/1"])
    func aChromiumTabThatReachesAProtectedMediaSiteReopensInWebKit(url: String) {
        #expect(navigation(url).reopensInWebKit)
    }

    @Test func aTabThatStaysOffTheRuleKeepsChromium() {
        #expect(!navigation("https://music.youtube.com/").reopensInWebKit)
        #expect(!navigation("https://example.com/").reopensInWebKit)
    }

    @Test func aWebKitPinnedReopenedOrAgentTabDoesNotMove() {
        let spotify = "https://open.spotify.com/"
        #expect(!navigation(spotify, chromium: false).reopensInWebKit, "a WebKit tab is already there")
        #expect(!navigation(spotify, pinned: true).reopensInWebKit, "--engine chromium wins")
        #expect(!navigation(spotify, reopened: true).reopensInWebKit, "once per tab")
        #expect(!navigation(spotify, agent: true).reopensInWebKit, "an agent's tab stays under the agent")
    }

    @Test func aChromiumSiteRuleNeverMovesATab() {
        let rules = BrowserSiteEngines(rules: ["spotify.com": .chromium])
        let move = BrowserSiteEngineNavigation(siteEngine: rules.engine(for: URL(string: "https://open.spotify.com/")),
                                               engineIsChromium: true, enginePinned: false, alreadyReopened: false, agentDriven: false)
        #expect(!move.reopensInWebKit, "a person who sends Spotify to Chromium keeps it there")
    }
}
