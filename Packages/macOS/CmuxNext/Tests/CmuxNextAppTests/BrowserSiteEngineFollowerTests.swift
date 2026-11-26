import CmuxNextBrowser
import CmuxNextBrowserTabs
import CmuxNextSettings
import Foundation
import Testing

/// https://github.com/manaflow-ai/cmux/issues/45018: open.spotify.com typed on a Chromium New Tab page stayed in
/// Chromium ("Playback of protected content is not enabled"): `browser.siteEngines` was read only when a tab was
/// made with a URL. A Chromium tab that arrives at a WebKit site fresh (its first web page, or a typed address)
/// now reopens in WebKit; one a sign-in redirect took there, or a popup that keeps `window.opener`, stays.
/// The default list is empty since Chromium plays Widevine; these tests set a person's own `spotify.com` rule.
@MainActor @Suite(.serialized) struct BrowserSiteEngineFollowerTests {
    final class Host {
        var reopened: [(url: URL, background: Bool)] = []
        var tab: BrowserSiteEngineFollower.Tab? = .init(enginePinned: false, alreadyReopened: false, shown: true)
        lazy var follower = BrowserSiteEngineFollower(rules: { BrowserSiteEngines(rules: ["spotify.com": .webkit]) }, tab: { [unowned self] _ in tab },
                                                      reopen: { [unowned self] _, url, background in reopened.append((url, background)) })
    }

    static let spotify = URL(string: "https://open.spotify.com/")!

    static func page(_ start: String, kind: BrowserEngineKind = .cef) -> (MockBrowserTab, BrowserEntry) {
        let page = MockBrowserEngine(kind: kind).makeMockTab(BrowserTabConfiguration(initialURL: URL(string: start)))
        page.load(URL(string: start)!)
        return (page, BrowserEntry(tab: page))
    }

    static func settle() async { for _ in 0..<8 { await Task.yield() } }

    @Test func spotifyTypedOnTheChromiumNewTabPageReopensInWebKit() async {
        let host = Host()
        let (page, entry) = Self.page(BrowserNewTabPage.chromiumURL)
        defer { entry.close() }
        host.follower.follow(entry.state, page: page)
        host.follower.typedCommit(page)
        page.load(Self.spotify)
        await Self.settle()
        #expect(host.reopened.map(\.url) == [Self.spotify], "the tab moved to WebKit once: \(host.reopened)")
        #expect(host.reopened.first?.background == false, "the shown tab's WebKit tab takes its place in front")
    }

    @Test func aRestoredSpotifyTabReopensInWebKitBehindWhenHidden() async {
        let host = Host()
        host.tab?.shown = false
        let (page, entry) = Self.page("https://open.spotify.com/track/1")
        defer { entry.close() }
        host.follower.follow(entry.state, page: page)
        await Self.settle()
        #expect(host.reopened.map(\.url.absoluteString) == ["https://open.spotify.com/track/1"])
        #expect(host.reopened.first?.background == true, "a hidden tab's move does not take selection or focus")
    }

    @Test func aSignInRedirectFromAnotherSiteStaysInChromium() async {
        let host = Host()
        let (page, entry) = Self.page("https://example.com/")
        defer { entry.close() }
        host.follower.follow(entry.state, page: page)
        await Self.settle()
        page.load(URL(string: "https://accounts.spotify.com/authorize?client_id=x")!)
        await Self.settle()
        #expect(host.reopened.isEmpty, "the redirect keeps example.com's Chromium cookies: \(host.reopened)")
    }

    @Test func aPopupThatKeepsItsOpenerStaysInChromium() async {
        let host = Host()
        let (page, entry) = Self.page(BrowserNewTabPage.blankURL)
        defer { entry.close() }
        host.follower.keepsOpener(page)
        host.follower.follow(entry.state, page: page)
        page.load(Self.spotify)
        await Self.settle()
        #expect(host.reopened.isEmpty)
    }

    @Test func aPinnedReopenedOrWebKitTabStays() async {
        for tab in [BrowserSiteEngineFollower.Tab(enginePinned: true, alreadyReopened: false, shown: true),
                    BrowserSiteEngineFollower.Tab(enginePinned: false, alreadyReopened: true, shown: true)] {
            let host = Host()
            host.tab = tab
            let (page, entry) = Self.page(BrowserNewTabPage.chromiumURL)
            host.follower.follow(entry.state, page: page)
            page.load(Self.spotify)
            await Self.settle()
            #expect(host.reopened.isEmpty, "\(tab)")
            entry.close()
        }
        let host = Host()
        let (page, entry) = Self.page(BrowserNewTabPage.blankURL, kind: .webkit)
        defer { entry.close() }
        host.follower.follow(entry.state, page: page)
        page.load(Self.spotify)
        await Self.settle()
        #expect(host.reopened.isEmpty, "a WebKit tab is already there")
    }

    @Test func aStandInMovesOnceWhenItBecomesItsDaemonTab() async {
        let host = Host()
        host.tab = nil
        let (page, entry) = Self.page(BrowserNewTabPage.chromiumURL)
        defer { entry.close() }
        host.follower.follow(entry.state, page: page)
        page.load(Self.spotify)
        await Self.settle()
        #expect(host.reopened.isEmpty, "no tab yet: the move waits")
        host.tab = .init(enginePinned: false, alreadyReopened: false, shown: true)
        host.follower.follow(entry.state, page: page)
        await Self.settle()
        #expect(host.reopened.map(\.url) == [Self.spotify])
    }

    @Test func otherSitesStayInChromium() async {
        let host = Host()
        let (page, entry) = Self.page(BrowserNewTabPage.chromiumURL)
        defer { entry.close() }
        host.follower.follow(entry.state, page: page)
        page.load(URL(string: "https://music.youtube.com/")!)
        await Self.settle()
        #expect(host.reopened.isEmpty)
    }
}
