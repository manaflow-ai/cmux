import AppKit
import CmuxNextDesign
import Testing
@testable import CmuxNextSidebar

/// `window.rail` moves the sticky sections out of the sidebar and into the
/// rail column, which draws them from the same model: hidden items stay
/// hidden, and a press activates the item as in the sidebar.
@MainActor @Suite(.serialized) struct SidebarRailColumnTests {
    private func sidebar(rail: WindowRailPlacement) -> SidebarView {
        DesignSettings.shared.rail = rail
        let view = SidebarView(model: SidebarModel())
        view.frame = NSRect(x: 0, y: 0, width: 240, height: 700)
        view.layoutSubtreeIfNeeded()
        return view
    }

    @Test func theSidebarDropsItsBandsWhileTheRailShowsThem() {
        let saved = DesignSettings.shared.rail
        defer { DesignSettings.shared.rail = saved }
        let plain = sidebar(rail: .off)
        #expect(!plain.aboveRegion.layoutResult.rows.isEmpty)
        #expect(!plain.belowRegion.layoutResult.rows.isEmpty)
        for placement in [WindowRailPlacement.leading, .afterSidebar] {
            let railed = sidebar(rail: placement)
            #expect(railed.aboveRegion.layoutResult.rows.isEmpty, "\(placement)")
            #expect(railed.belowRegion.layoutResult.rows.isEmpty, "\(placement)")
        }
    }

    @Test func theColumnDrawsTheModelsBandsWithoutHiddenItems() throws {
        let model = SidebarModel()
        let appStore = LayoutItemID("itm_app_store")
        model.itemInfo[appStore] = SidebarItemInfo(title: "App Store", symbol: "bag", isHidden: true)
        let column = SidebarRailColumnView(model: model)
        column.frame = NSRect(x: 0, y: 0, width: 48, height: 600)
        column.topInset = 40
        column.layoutSubtreeIfNeeded()
        let items = column.layoutResult.buttons.map(\.item)
        #expect(items == [LayoutItemID("itm_home"), LayoutItemID("itm_settings"), LayoutItemID("itm_account")])
        #expect(column.layoutResult.buttons.first?.frame.minY == 40)
        #expect(column.itemView(appStore) == nil)
    }

    @Test func theColumnUsesTheAppsToolTips() throws {
        let column = SidebarRailColumnView(model: SidebarModel())
        column.frame = NSRect(x: 0, y: 0, width: 48, height: 600)
        column.toolTipProvider = { $0.builtIn == .settings ? "Settings (⌘,)" : nil }
        column.layoutSubtreeIfNeeded()
        #expect(try #require(column.itemView(LayoutItemID("itm_settings"))).toolTip == "Settings (⌘,)")
        #expect(try #require(column.itemView(LayoutItemID("itm_home"))).toolTip == SidebarBuiltIn.home.title)
    }
}
