@testable import CmuxNextApp
@testable import CmuxNextSidebar
import CmuxNextSettings
import CmuxNextUpdater
import Foundation
import Testing

@MainActor
struct LaunchPolishVisibilityTests {
    @Test func appStoreStaysInStoredLayoutButIsFilteredWhenPreviewFeaturesAreOff() {
        let stored = SidebarLayoutDocument.defaults
        let hidden = SidebarRows.visibleLayout(stored, showAppStore: false)
        #expect(stored.firstItem(with: .app("cmux/app-store")) != nil)
        #expect(hidden.firstItem(with: .app("cmux/app-store")) == nil)
        #expect(SidebarRows.visibleLayout(stored, showAppStore: true) == stored.withoutChats)
    }
    @Test func whatsNewCardShowsAfterAnUpdateWithPreviewsOffByDefault() async throws {
        // User 13935: What's New shows after every update, no Labs gate; a Settings toggle turns it off.
        let suite = "launch-polish-visibility-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
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
        let defaults = try #require(UserDefaults(suiteName: suite))
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
}
