import AppKit
import Testing
@testable import CmuxNextSidebar

/// WHATS-NEW-AFTER-UPDATE W1: a client-only item (What's New after an
/// update) draws at the very top of the top band, above Home, with an
/// unread dot; it activates like any item but never drags or edits, and it
/// is never written to the layout document.
@MainActor
@Suite struct SidebarTransientItemTests {
    let id = LayoutItemID(LayoutItemID.transientPrefix + "whats-new")

    private func whatsNew(dot: Bool = true) -> SidebarTransientItem {
        var info = SidebarItemInfo(title: "What's New", symbol: "sparkles")
        info.unreadDot = dot
        return SidebarTransientItem(id: id, info: info)
    }

    private func sidebar(_ model: SidebarModel) -> SidebarView {
        let view = SidebarView(model: model)
        view.frame = NSRect(x: 0, y: 0, width: 260, height: 700)
        view.layoutSubtreeIfNeeded()
        return view
    }

    @Test func itDrawsAboveHomeWithAnUnreadDot() throws {
        let model = SidebarModel()
        model.transientTopItems = [whatsNew()]
        let view = sidebar(model)
        let item = try #require(view.aboveRegion.itemView(id))
        let home = try #require(view.aboveRegion.itemView(LayoutItemID("itm_home")))
        #expect(item.frame.minY < home.frame.minY)
        #expect(item.info.title == "What's New")
        #expect(item.isBadgeShown)
        let dot = try #require(item.badgeFrame)
        #expect(dot.width == dot.height)
        #expect(model.layout.item(id) == nil)
    }

    @Test func clickingItSendsActivate() throws {
        let model = SidebarModel()
        var sent: [SidebarIntent] = []
        model.onIntent = { sent.append($0) }
        model.transientTopItems = [whatsNew()]
        let view = sidebar(model)
        #expect(try #require(view.aboveRegion.itemView(id)).accessibilityPerformPress())
        #expect(sent == [.activateItem(id)])
    }

    @Test func removingItTakesItsRowAway() {
        let model = SidebarModel()
        model.transientTopItems = [whatsNew()]
        let view = sidebar(model)
        #expect(view.aboveRegion.itemView(id) != nil)
        model.transientTopItems = []
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
        #expect(view.aboveRegion.itemView(id) == nil)
        #expect(view.aboveRegion.itemView(LayoutItemID("itm_home")) != nil)
    }

    @Test func aDotWithoutACountDrawsInEveryLook() {
        for style in [SidebarItemRowView.Style.builtIn, .list, .chip, .icon, .tile, .favorite] {
            let row = SidebarItemRowView(frame: NSRect(x: 0, y: 0, width: 200, height: 28))
            row.configure(whatsNew().info, style: style)
            row.layoutSubtreeIfNeeded()
            #expect(row.isBadgeShown, "\(style)")
        }
        let read = SidebarItemRowView(frame: NSRect(x: 0, y: 0, width: 200, height: 28))
        read.configure(whatsNew(dot: false).info, style: .builtIn)
        #expect(!read.isBadgeShown)
    }

    @Test func transientIdsAreRecognized() {
        #expect(id.isTransient)
        #expect(!LayoutItemID("itm_home").isTransient)
    }
}
