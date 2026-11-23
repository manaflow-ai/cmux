import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// The Chief listed in a machine list or a group (#23933). Its row shows a status or unread change as soon as the
/// App's item info has it, though nothing else changed to reload the list, in the band's colors.
@MainActor @Suite(.serialized)
struct ChiefListedRowTests {
    static let chief = SidebarListItem(id: "itm_chief", ref: .builtIn(.chief), title: SidebarBuiltIn.chief.title)
    static let chiefKey = SidebarRowKey.item(chief.id)

    /// The sidebar document's list: `w1`, the Chief and `w2` in this Mac's list.
    static func sidebar() -> (SidebarModel, SidebarView, NSWindow) {
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let ws = { (id: String) in SidebarWorkspace(id: WorkspaceID(id), title: id) }
        let model = SidebarModel(sections: [CmuxNextSidebar.SidebarSection(kind: .machine(machine), nodes: [
            .workspace(ws("w1")), .item(chief), .workspace(ws("w2")),
        ])], activeWorkspaceID: WorkspaceID("w1"))
        model.layout = SidebarLayoutDocument(sections: [])
        model.itemInfo = [LayoutItemID(chief.id): SidebarBuiltIn.chief.defaultInfo]
        let sidebar = SidebarView(model: model, design: DesignSettings.shared)
        sidebar.frame = NSRect(x: 0, y: 0, width: 240, height: 360)
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 600, height: 360), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(sidebar)
        window.orderFrontRegardless()
        sidebar.renderNow()
        settle(sidebar)
        sidebar.list.reload(animated: false)
        settle(sidebar)
        return (model, sidebar, window)
    }

    static func settle(_ sidebar: SidebarView) {
        sidebar.layoutSubtreeIfNeeded()
        sidebar.list.fitToClip()
        sidebar.layoutSubtreeIfNeeded()
    }

    /// The Chief starts waiting with two subagents that need you, then only its conversation is unread: the
    /// App's item info changes and nothing else. The row it already drew shows both, in place.
    @Test func aStatusOrUnreadChangeShowsOnTheListedChiefsRow() throws {
        let (model, sidebar, window) = Self.sidebar()
        defer { window.orderOut(nil) }
        let row = try #require(sidebar.list.rowViews[Self.chiefKey] as? SidebarItemListRowView, "the list draws no Chief row")
        #expect(row.accessibilityValue() as? String == nil)

        var info = SidebarBuiltIn.chief.defaultInfo
        info.activity = .waiting
        info.badge = 2
        model.itemInfo[LayoutItemID(Self.chief.id)] = info
        sidebar.renderNow()
        Self.settle(sidebar)
        #expect(row.accessibilityValue() as? String == "2", "the Chief's row kept its old badge")
        let activity = try #require(row.subviews.lazy.compactMap { $0 as? StatusIndicatorView }.first, "the row draws no status")
        #expect(activity.usesStatusColors, "the listed Chief's status draws the theme's colors, not the band's status colors")

        info.badge = nil
        info.unreadDot = true
        model.itemInfo[LayoutItemID(Self.chief.id)] = info
        sidebar.renderNow()
        Self.settle(sidebar)
        #expect(row.accessibilityValue() as? String == Strings.unreadDot, "the Chief's row shows no unread dot")
        let badge = try #require(row.subviews.lazy.compactMap { $0 as? UnreadBadgeView }.first, "the row draws no badge")
        #expect(badge.notificationDot, "the listed Chief's dot is the badge's, not Home's blue unread dot")
        #expect(sidebar.list.rowViews[Self.chiefKey] === row, "the row was drawn again in a new view, not patched")
    }
}
