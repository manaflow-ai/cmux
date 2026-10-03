@testable import CmuxNextApp
import CmuxNextBrowser
import CmuxNextDaemon
import Foundation
import Testing

/// Coordinator decision 2026-09-30: an incognito tab is never written to
/// the daemon's database. The daemon gets only an opaque placeholder record;
/// the URL, title and favicon stay in the app's memory.
@MainActor
struct IncognitoRecordTests {
    static let secret = "https://secret.example/private?q=1"

    @Test func anIncognitoTabIsCreatedWithAPlaceholderURL() async throws {
        let services = ActionBindingCoverageTests.boundServices()
        let browserTabs = try #require(services.cache.browserTabs)
        var created: [String] = []
        browserTabs.create = { _, url, _, _ in
            created.append(url)
            return SurfaceID(rawValue: 9)
        }
        browserTabs.isIncognitoPane = { _ in true }
        let surface = try await browserTabs.open(BrowserEngineChoice(engine: .cef), in: PaneID(rawValue: 3), url: Self.secret)
        // An explicit incognito open (a new incognito window's first tab)
        // behaves the same when the pane is not known yet.
        browserTabs.isIncognitoPane = { _ in false }
        _ = try await browserTabs.open(BrowserEngineChoice(engine: .cef), in: PaneID(rawValue: 4), url: Self.secret, incognito: true)
        #expect(created == [BrowserTabService.incognitoPlaceholderURL, BrowserTabService.incognitoPlaceholderURL])
        #expect(!created.contains { $0.contains("secret") })

        // The page still starts on the real URL, from memory.
        let tab = #"{"kind":"browser","name":"","surface":9,"dead":false,"browser_renderer":"frontend","browser_engine":"cef","url":"about:blank"}"#
        services.daemon.store.apply(snapshot: try BrowserRecordMoveTests.tree(pane: 3, tab: tab))
        let model = try #require(services.daemon.store.workspaces.first?.screens.first?.panes.first?.tabs.first)
        #expect(surface == SurfaceID(rawValue: 9))
        #expect(browserTabs.startURL(for: model) == Self.secret)
        withExtendedLifetime(services) {}
    }

    @Test func anIncognitoPageIsNeverWrittenBack() async throws {
        let services = ActionBindingCoverageTests.boundServices()
        let store = services.daemon.store
        let tab = #"{"kind":"browser","name":"","surface":9,"dead":false,"browser_renderer":"frontend","browser_engine":"cef","url":"about:blank"}"#
        store.apply(snapshot: try BrowserRecordMoveTests.tree(pane: 3, tab: tab))
        let browserTabs = try #require(services.cache.browserTabs)
        var sent: [BrowserRecordUpdate] = []
        browserTabs.update = { _, update in
            sent.append(update)
            return true
        }
        browserTabs.sleep = { _ in }
        browserTabs.isIncognitoTab = { _ in true }
        let page = MockBrowserEngine().makeMockTab(BrowserTabConfiguration())
        let model = try #require(store.workspaces.first?.screens.first?.panes.first?.tabs.first)
        browserTabs.track(page, for: model)
        page.load(URL(string: Self.secret)!)
        page.simulate(.titleChanged("Private page"))
        for _ in 0..<500 { await Task.yield() }
        #expect(sent.isEmpty)
        withExtendedLifetime(services) {}
    }
}

/// A new incognito tab showed "about:blank" as its title; it must show
/// "New Tab".
struct IncognitoTabTitleTests {
    @Test func aBlankPageHasNoTitleOfItsOwn() {
        #expect(TabContentCache.incognitoTitle("about:blank", url: URL(string: "about:blank")) == nil)
        #expect(TabContentCache.incognitoTitle(nil, url: nil) == nil)
        #expect(TabContentCache.incognitoTitle("", url: URL(string: "https://a.test/x")) == "a.test")
        #expect(TabContentCache.incognitoTitle("Docs", url: URL(string: "https://a.test/x")) == "Docs")
    }
}
