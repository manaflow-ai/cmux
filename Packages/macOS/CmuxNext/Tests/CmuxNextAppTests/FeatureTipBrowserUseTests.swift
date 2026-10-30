import AppKit
@testable import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextBridge
import CmuxNextTestSupport
import Foundation
import Testing

/// Feature tips: any browser page, by any path, records the browser as used, so the Browser tip never
/// shows (Leo, 2026-10-30: "no this should be very very infrequent like app installation level
/// frequent and if they havent used the browser"). Every page passes `TabContentCache.mount`;
/// a pane's session-local tab (`PaneController.content(for:)`, a `LocalBrowserTab`) comes through
/// `browser(for:url:profile:)`, which the first version of the hook missed.
@MainActor @Suite(.serialized) struct FeatureTipBrowserUseTests {
    init() { _ = NSApplication.shared }

    private func records() throws -> AgentPaneFeatureTipRecords {
        let suite = "FeatureTipBrowserUseTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return AgentPaneFeatureTipRecords(defaults: defaults)
    }

    /// The call PaneController makes for a LocalBrowserTab marks the browser used, once per page.
    @Test func aLocalBrowserTabMarksTheBrowserUsed() throws {
        let services = AppServices(environment: AppEnvironment.current([:]))
        let store = try records()
        var notes = 0
        services.cache.onBrowserTab = { notes += 1; store.noteFeatureUsed(AgentPaneFeatureTipRecords.browserFeature) }
        let local = LocalBrowserTab.make(url: URL(string: "https://example.com/local"))
        defer { services.cache.release(local.id) }
        #expect(store.usedFeatures.isEmpty)
        _ = services.cache.browser(for: local.id, url: local.url, profile: nil)
        #expect(store.usedFeatures == [AgentPaneFeatureTipRecords.browserFeature])
        #expect(!store.claim("agents-drive-visible-browser-tabs", feature: AgentPaneFeatureTipRecords.browserFeature))
        _ = services.cache.browser(for: local.id, url: local.url, profile: nil)
        #expect(notes == 1, "a page shown again is not a new page")
    }

    /// The app wires the hook to the install's records by default.
    @Test func theAppWiresTheHook() {
        let services = AppServices(environment: AppEnvironment.current([:]))
        #expect(services.cache.onBrowserTab != nil)
    }
}
