import Testing
@testable import CmuxNextApp
@testable import CmuxNextSidebar
@testable import CmuxNextUpdater

/// R53 (coordinator 2026-10-03): the update circle left with the window
/// rail; a staged update shows as a badge on the Settings item (R114: only
/// once it is ready), and one click on the badge installs it.
@MainActor @Suite(.serialized, .timeLimit(.minutes(2))) struct SettingsUpdateBadgeTests {
    @Test func settingsCarriesTheUpdateBadgeOnlyWhileAnUpdateIsAvailable() {
        let with = SidebarBridge.itemInfo(for: .defaults, registered: { _ in true }, updateAvailable: true)
        let without = SidebarBridge.itemInfo(for: .defaults, registered: { _ in true }, updateAvailable: false)
        #expect(with[LayoutItemID("itm_settings")]?.accessory == .update)
        #expect(with[LayoutItemID("itm_home")]?.accessory == nil)
        #expect(without[LayoutItemID("itm_settings")]?.accessory == nil)
    }

    /// R114: one click on the badge installs the staged update at once.
    @Test func theBadgeInstallsTheStagedUpdate() async throws {
        let harness = try await ViewChangePermissionTests.harness()
        defer { harness.stop() }
        var presented = 0, installs = 0
        harness.services.updater.presentUpdateUI = { presented += 1 }
        harness.services.updater.installStaged = { installs += 1 }
        harness.services.updater.debugIndicatorPhase = .ready(version: "2")
        harness.window.sidebar.handle(.activateItemAccessory(LayoutItemID("itm_settings")))
        #expect(installs == 1)
        #expect(presented == 0)
    }
}
