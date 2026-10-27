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
    @Test func whatsNewCardRemainsHiddenByDefaultAndReturnsWhenPreviewsAreEnabled() async throws {
        let suite = "launch-polish-visibility-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let center = WhatsNewCenter(currentVersion: "1.0.0", defaults: defaults, sources: [])
        var settings = CmuxConfigSnapshot()
        #expect(!settings.previewFeatures)
        center.isItemEnabled = settings.previewFeatures && settings.updates.showWhatsNew
        await center.load().value
        #expect(center.debugPretendUpdated(from: "0.9.0"))
        #expect(!center.showsUpdatedCard)

        settings.previewFeatures = true
        center.isItemEnabled = settings.previewFeatures && settings.updates.showWhatsNew
        #expect(center.showsUpdatedCard)
        settings.previewFeatures = false
        center.isItemEnabled = settings.previewFeatures && settings.updates.showWhatsNew
        #expect(!center.showsUpdatedCard)
        #expect(center.isUpdated, "hiding the card preserves the update for when previews are enabled")
    }
}
