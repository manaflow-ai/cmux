import AppKit
import CmuxNextAgentActivity
@testable import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextBridge
import CmuxNextBrowser
@testable import CmuxNextDaemon
import CmuxNextHistory
import CmuxNextTestSupport
import Foundation
import Testing

/// Feature tips: every web page a browser tab gets, by any path, records the browser as used, and the
/// app's own pages in a browser tab do not (Leo, 2026-10-30: "no this should be very very infrequent
/// like app installation level frequent and if they havent used the browser"). Every page passes
/// `TabContentCache.mount`, which fires `onBrowserTab` for `isBrowserPage` kinds only. Reviews of the
/// first two versions: a pane's session-local tab missed the hook (765b13af); then History and Agent
/// Activity counted as browser use (ea343646).
@MainActor @Suite(.serialized) struct FeatureTipBrowserUseTests {
    init() { _ = NSApplication.shared }

    /// A cache whose browser-use hook counts its calls.
    private func counting(_ cache: TabContentCache) -> () -> Int {
        var notes = 0
        cache.onBrowserTab = { notes += 1 }
        return { notes }
    }

    /// The call PaneController makes for a LocalBrowserTab marks the browser used, once per page, and the
    /// install's records then refuse the Browser tip.
    @Test func aLocalBrowserTabMarksTheBrowserUsed() throws {
        let services = AppServices(environment: AppEnvironment.current([:]))
        let suite = "FeatureTipBrowserUseTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let store = AgentPaneFeatureTipRecords(defaults: defaults)
        var notes = 0
        services.cache.onBrowserTab = { notes += 1; store.noteFeatureUsed(AgentPaneFeatureTipRecords.browserFeature) }
        let local = LocalBrowserTab.make(url: URL(string: "https://example.com/local"))
        defer { services.cache.release(local.id) }
        _ = services.cache.browser(for: local.id, url: local.url, profile: nil)
        #expect(store.usedFeatures == [AgentPaneFeatureTipRecords.browserFeature])
        #expect(!store.claim("agents-drive-visible-browser-tabs", feature: AgentPaneFeatureTipRecords.browserFeature))
        _ = services.cache.browser(for: local.id, url: local.url, profile: nil)
        #expect(notes == 1, "a page shown again is not a new page")
    }

    /// A daemon browser tab's page marks it.
    @Test func aDaemonBrowserTabMarksTheBrowserUsed() throws {
        let cache = TabContentCache(daemon: DaemonService(), cef: CEFEngine(layout: nil, stores: .inMemory(), signInCallbacks: CEFSignInCallbacks()),
                                    fileInput: NoFileInput())
        let notes = counting(cache)
        let tab = TabModel(TabSnapshot(surface: SurfaceID(rawValue: 7101), kind: .browser, url: "https://example.com/daemon",
                                       browserRenderer: "frontend", browserEngine: "webkit"))
        defer { cache.release(tab.id) }
        let entry = try #require(cache.browser(for: tab))
        #expect(TabContentCache.isBrowserPage(entry.tab))
        #expect(notes() == 1)
    }

    /// A popup or a link opened in a new tab is a page the cache adopts (`install`): it marks it.
    @Test func aPopupMarksTheBrowserUsed() {
        let services = AppServices(environment: AppEnvironment.current([:]))
        let notes = counting(services.cache)
        let popup = services.cache.webKit.makeWebKitTab(profile: .default, initialURL: URL(string: "https://example.com/popup"))
        defer { services.cache.release("feature-tip-popup") }
        services.cache.install(popup, for: "feature-tip-popup")
        #expect(notes() == 1)
    }

    /// History and Agent Activity open in a browser tab but are the app's own pages: no browser use.
    @Test(arguments: [HistoryPageAddress.string, AgentActivityPageAddress.string])
    func anAppPageIsNotBrowserUse(_ address: String) throws {
        let services = AppServices(environment: AppEnvironment.current([:]))
        let notes = counting(services.cache)
        let tab = TabModel(TabSnapshot(surface: SurfaceID(rawValue: address == HistoryPageAddress.string ? 7102 : 7103), kind: .browser,
                                       url: address, browserRenderer: "frontend", browserEngine: "webkit"))
        defer { services.cache.release(tab.id) }
        let entry = try #require(services.cache.appPage(for: tab, url: URL(string: address)))
        #expect(!TabContentCache.isBrowserPage(entry.tab))
        #expect(notes() == 0)
    }

    /// The app wires the hook to the install's records by default.
    @Test func theAppWiresTheHook() {
        let services = AppServices(environment: AppEnvironment.current([:]))
        #expect(services.cache.onBrowserTab != nil)
    }
}
