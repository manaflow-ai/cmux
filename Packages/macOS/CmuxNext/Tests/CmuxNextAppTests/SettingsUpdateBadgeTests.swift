import Testing
@testable import CmuxNextApp
@testable import CmuxNextSidebar
import CmuxNextUpdater

/// R53 (coordinator 2026-10-03): the update circle left with the window
/// rail; an available update now shows as a badge on the Settings item,
/// and a click on the badge opens the updater sheet.
@MainActor @Suite(.serialized, .timeLimit(.minutes(2))) struct SettingsUpdateBadgeTests {
    @Test func settingsCarriesTheUpdateBadgeOnlyWhileAnUpdateIsAvailable() {
        let with = SidebarBridge.itemInfo(for: .defaults, registered: { _ in true }, updateAvailable: true)
        let without = SidebarBridge.itemInfo(for: .defaults, registered: { _ in true }, updateAvailable: false)
        #expect(with[LayoutItemID("itm_settings")]?.accessory == .update)
        #expect(with[LayoutItemID("itm_home")]?.accessory == nil)
        #expect(without[LayoutItemID("itm_settings")]?.accessory == nil)
    }

    @Test func theBadgeOpensTheUpdater() async throws {
        let harness = try await ViewChangePermissionTests.harness()
        defer { harness.stop() }
        var presented = 0
        harness.services.updater.presentUpdateUI = { presented += 1 }
        harness.window.sidebar.handle(.activateItemAccessory(LayoutItemID("itm_settings")))
        #expect(presented == 1)
    }
}
