import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextPages
@testable import CmuxNextSidebar
import CmuxNextSettings
import CmuxNextTestSupport
@testable import CmuxNextUpdater
import Foundation
import Testing

@MainActor
struct LaunchPolishVisibilityTests {
    /// The stored layout keeps the App Store; with Labs off its item info hides it (AppStoreHiddenUntilReadyTests).
    @Test func appStoreIsDrawnFromTheStoredLayout() {
        let stored = SidebarLayoutDocument.defaults
        #expect(stored.firstItem(with: .app("cmux/app-store")) != nil)
        #expect(SidebarRows.visibleLayout(stored) == stored.withoutChats)
        #expect(SidebarRows.visibleLayout(stored).firstItem(with: .app("cmux/app-store")) != nil)
    }
    @Test func whatsNewCardShowsAfterAnUpdateWithPreviewsOffByDefault() async throws {
        // User 13935: What's New shows after every update, no Labs gate; a Settings toggle turns it off.
        let suite = "launch-polish-visibility-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(testSuiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let center = WhatsNewCenter(currentVersion: "1.0.0", defaults: defaults, sources: [])
        let settings = CmuxConfigSnapshot.parse(.object([:]), validDensities: [], validMetrics: [])
        #expect(!settings.previewFeatures)
        #expect(settings.updates.showWhatsNew == true)
        center.isItemEnabled = settings.updates.showWhatsNew
        await center.load().value
        #expect(center.debugPretendUpdated(from: "0.9.0"))
        #expect(center.showsUpdatedCard)
    }

    @Test func whatsNewCardHidesWhenTheSettingIsTurnedOffAndKeepsTheUpdate() async throws {
        let suite = "launch-polish-visibility-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(testSuiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let center = WhatsNewCenter(currentVersion: "1.0.0", defaults: defaults, sources: [])
        var settings = CmuxConfigSnapshot.parse(.object([:]), validDensities: [], validMetrics: [])
        settings.updates.showWhatsNew = false
        center.isItemEnabled = settings.updates.showWhatsNew
        await center.load().value
        #expect(center.debugPretendUpdated(from: "0.9.0"))
        #expect(!center.showsUpdatedCard)
        #expect(center.isUpdated, "hiding the card preserves the update")
    }

    /// Leo 2026-10-30: "WHAT GOOD REASON DO WE HAVE IN THE FIRST PLACE TO KEEP THIS SHIT IN FUCKING
    /// LABS IF I FUCKING ASKED FOR THESE FUCKING FEATURES". The palette's and Help menu's What's New
    /// (`updates.whatsNew`) is available with Labs off, the default; the App Store is a Labs preview until it is ready.
    @Test func whatsNewActionIsAvailableWithLabsOff() {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        #expect(services.settings?.snapshot.previewFeatures != true)
        #expect(services.registry.unavailableReason(for: "updates.whatsNew") == nil,
                "What's New in the palette and Help menu is still behind Labs")
        #expect(services.registry.settingOffReason("appStore.show") != nil, "the App Store shows with Labs off")
    }

    /// The update this launch came from, as the old build recorded it.
    static let lastUpdate = WhatsNewLastUpdate(fromVersion: "0.9.0", fromBuild: "90", toVersion: "1.0.0", toBuild: "100",
                                               stagedAt: Date(timeIntervalSince1970: 0),
                                               changelog: UpdateChangelog(version: "1.0.0", date: nil, lines: ["A change"]))

    /// Seeds the last update on `updater` and records what its changelog openers get.
    static func recordOpens(_ updater: UpdaterService) -> () -> (spans: [[String]], plain: Int) {
        updater.whatsNew.lastUpdate = lastUpdate
        var spans: [[String]] = [], plain = 0
        updater.openChangelog = { plain += 1; return true }
        updater.openChangelogSpan = { from, to, _ in spans.append([from, to]); return true }
        return { (spans, plain) }
    }

    /// The span the opener gets becomes the changelog tab's route (`#/?from=&to=`).
    @Test func theUpdatesSpanIsTheChangelogTabsRoute() {
        #expect(WhatsNewDesign.sheet.changelogRoute(from: "0.9.0", to: "1.0.0") == "#/?from=0.9.0&to=1.0.0")
    }
}
