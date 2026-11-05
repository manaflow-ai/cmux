import AppKit
@testable import CmuxNextActions
import Testing

/// The tab bar's empty-area menu, the strip's or the vertical list's (Leo 2026-10-20, from Edge's
/// and Chrome's vertical-tab menus): New Tab, Reopen Closed Tab, Bookmark All Tabs, Move All Tabs to
/// a New Workspace; the vertical tabs rows; Task Manager.
@MainActor
struct TabStripMenuTests {
    @Test func theTabBarMenuListsEdgesAndChromesRowsInOrder() {
        let rows = ContextMenuCatalog.shared.entries(for: .tabStrip).map { entry -> String in
            switch entry {
            case .action(let id): id.rawValue
            case .separator: "—"
            default: "unexpected \(entry)"
            }
        }
        #expect(rows == [
            "newTab.default", "reopenClosedBrowserPanel", "bookmark.addAllTabs", "pane.moveToNewWorkspace", "—",
            "tabs.verticalTabs.toggle", "tabs.verticalTabs.allWorkspaces", "tabs.verticalTabs.collapse", "tabs.verticalTabs.expandOnHover", "—",
            "palette.openTaskManager",
        ])
    }

    @Test func itsRowsReadAsEdgesAndChromesDo() {
        let registry = ActionRegistry.standard()
        registry.context = ActionContext(rawValue: .max)
        let menu = registry.makeContextMenu(for: .tabStrip, target: ActionTargetRef(kind: .pane, id: "p1"))
        #expect(menu.items.map { $0.isSeparatorItem ? "—" : $0.title } == [
            "New Tab", "Reopen Closed Tab", "Bookmark All Tabs…", "Move All Tabs to a New Workspace", "—",
            "Turn On Vertical Tabs", "Use Vertical Tabs for All Workspaces", "Collapse Tabs", "Auto-Expand Tabs on Hover", "—",
            "Task Manager",
        ])
    }

    /// The palette keeps each action's own title; only this menu uses Edge's shorter words.
    @Test func thePaletteKeepsTheActionsOwnTitles() {
        let byID = Dictionary(ActionCatalog.all.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
        #expect(byID["reopenClosedBrowserPanel"] == "Reopen Last Closed Tab")
        #expect(byID["pane.moveToNewWorkspace"] == "Move Pane to New Workspace")
    }
}
