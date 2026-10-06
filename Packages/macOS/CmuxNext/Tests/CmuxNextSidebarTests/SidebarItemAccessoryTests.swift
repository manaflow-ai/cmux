import AppKit
import Testing
@testable import CmuxNextSidebar

/// R53 (coordinator 2026-10-03): with the window rail gone, an available
/// update shows as a small badge on the Settings item; a click on the
/// badge opens the updater, a click elsewhere on Settings opens Settings.
@MainActor @Suite struct SidebarItemAccessoryTests {
    private func settingsRow(accessory: SidebarItemAccessory?) -> SidebarItemRowView {
        var info = SidebarItemInfo(title: "Settings", symbol: "gearshape")
        info.accessory = accessory
        let row = SidebarItemRowView(frame: NSRect(x: 0, y: 0, width: 180, height: 28))
        row.configure(info, style: .chip)
        row.layoutSubtreeIfNeeded()
        return row
    }

    @Test func anUpdateBadgeShowsOnlyWithTheAccessory() {
        #expect(settingsRow(accessory: .update(title: "Restart to Update")).isAccessoryShown)
        #expect(!settingsRow(accessory: nil).isAccessoryShown)
    }

    @Test func theBadgeRunsTheAccessoryAndTheRestRunsTheItem() throws {
        let row = settingsRow(accessory: .update(title: "Restart to Update"))
        var pressed = 0, accessory = 0
        row.onPress = { pressed += 1 }
        row.onAccessory = { accessory += 1 }
        let badge = try #require(row.accessoryFrame)
        #expect(badge.maxX <= row.bounds.maxX && badge.minX > row.bounds.midX, "trailing edge")
        row.press(at: NSPoint(x: badge.midX, y: badge.midY))
        #expect(accessory == 1 && pressed == 0)
        row.press(at: NSPoint(x: 20, y: 14))
        #expect(pressed == 1 && accessory == 1)
    }

    @Test func voiceOverReachesTheUpdateAction() {
        let row = settingsRow(accessory: .update(title: "Restart to Update"))
        var accessory = 0
        row.onAccessory = { accessory += 1 }
        let action = row.accessibilityCustomActions()?.first
        #expect(action?.name == "Restart to Update")
        _ = action?.handler?()
        #expect(accessory == 1)
    }
}
