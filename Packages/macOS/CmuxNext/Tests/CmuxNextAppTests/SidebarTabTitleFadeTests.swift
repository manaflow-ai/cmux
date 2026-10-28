import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// A listed tab's title shares its row with status marks and optional metadata.
/// Long names should fade at their available edge, as workspace titles do,
/// instead of ending with a hard clip before those controls.
@MainActor @Suite(.serialized)
struct SidebarTabTitleFadeTests {
    @Test func aLongTabTitleUsesTheSidebarFadeLabel() throws {
        _ = NSApplication.shared
        let workspace = WorkspaceID("ws-tab-fade")
        let title = String(repeating: "long-tab-title ", count: 12)
        let tab = SidebarTab(id: TabID("tab-fade"), title: title, kind: .terminal)
        let key = SidebarRowKey.tab(workspace, tab.id)
        let row = SidebarRow(key: key, y: 0, height: 24, section: .machine(.local), workspace: workspace,
                             siblingIndex: 0, isLastInGroup: true, isCollapsed: false, childCount: 1)
        let view = SidebarTabRowView(key: key)
        view.frame = NSRect(x: 0, y: 0, width: 180, height: 24)
        view.configure(tab, row: row)
        view.layoutSubtreeIfNeeded()

        let titleLabel = try #require(view.subviews.compactMap { $0 as? MarqueeLabel }.first)
        #expect(titleLabel.frame.width > 0)
        #expect(titleLabel.isTruncated)
    }
}
