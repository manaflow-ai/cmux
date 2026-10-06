import AppKit
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
    /// Lawrence 2026-10-05 ("i need this to look more minimal"): a staged
    /// update is one compact control on the Settings row, labelled Restart
    /// to Update for VoiceOver, and no card above the bottom band.
    @Test func aStagedUpdateIsOneCompactControlAndNoCard() async throws {
        let harness = try await ViewChangePermissionTests.harness()
        defer { harness.stop() }
        let updater = harness.services.updater
        updater.debugIndicatorPhase = .ready(version: "2")
        #expect(!SidebarCardFeed.cards(updater).contains { $0.id == SidebarCardFeed.updateCardID })
        let row = try Self.settingsRow(updater)
        #expect(row.isAccessoryShown)
        #expect(row.accessibilityCustomActions()?.map(\.name) == [UpdaterStrings.restartToUpdate])
    }

    @Test func noUpdateShowsNoControlAndNoCard() async throws {
        let harness = try await ViewChangePermissionTests.harness()
        defer { harness.stop() }
        let updater = harness.services.updater
        updater.debugIndicatorPhase = .hidden
        #expect(!SidebarCardFeed.cards(updater).contains { $0.id == SidebarCardFeed.updateCardID })
        let row = try Self.settingsRow(updater)
        #expect(!row.isAccessoryShown)
        #expect(row.accessibilityCustomActions() == nil)
    }

    /// The Settings row as the sidebar draws it for `updater`'s state.
    private static func settingsRow(_ updater: UpdaterService) throws -> SidebarItemRowView {
        let infos = SidebarBridge.itemInfo(for: .defaults, registered: { _ in true }, updateAvailable: updater.showsSettingsBadge)
        let info = try #require(infos[LayoutItemID("itm_settings")])
        let row = SidebarItemRowView(frame: NSRect(x: 0, y: 0, width: 240, height: 28))
        row.configure(info, style: .builtIn)
        row.layoutSubtreeIfNeeded()
        return row
    }
}
