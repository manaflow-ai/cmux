import CmuxNextBridge
import CmuxNextDaemon
import Testing

/// The work tab a browser front tab yields its row's name to (hq#1957,
/// https://github.com/manaflow-ai/cmux/issues/22249): the work the row was
/// named for before the page opened, so the most recently focused pane that
/// shows a chat or terminal, not the first one the workspace stores.
@MainActor
struct SidebarWorkTabTests {
    /// Terminals `a` and `b` in their own panes and a browser page in a third,
    /// each pane focused at the given time.
    private static func workspace(a: UInt64, b: UInt64, page: UInt64) throws -> WorkspaceModel {
        let store = DaemonStore()
        let panes = [
            PaneSnapshot(id: 1, focusedAt: a, tabs: [TabSnapshot(surface: 1, kind: .pty, title: "a")]),
            PaneSnapshot(id: 2, focusedAt: b, tabs: [TabSnapshot(surface: 2, kind: .pty, title: "b")]),
            PaneSnapshot(id: 3, focusedAt: page, tabs: [TabSnapshot(surface: 3, kind: .browser, title: "PR", url: "https://github.com")]),
        ]
        let layout = LayoutNode.split(id: nil, resourceID: nil, direction: .right, ratio: 0.5, a: .leaf(1),
                                      b: .split(id: nil, resourceID: nil, direction: .right, ratio: 0.5, a: .leaf(2), b: .leaf(3)))
        let screen = ScreenSnapshot(id: 1, layout: layout, panes: panes)
        store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "workspace-3", screens: [screen])]))
        return try #require(store.workspaces.first)
    }

    /// A page tab (Settings, a diff) gives the row no name, so the work tab passes over it.
    @Test func aPageTabIsNotWork() throws {
        let store = DaemonStore()
        var settings = TabSnapshot(surface: 2, kind: .conversation, title: "about:blank", url: "about:blank")
        settings.conversation = ConversationTabRef(page: "settings")
        let panes = [
            PaneSnapshot(id: 1, focusedAt: 1, tabs: [TabSnapshot(surface: 1, kind: .pty, title: "a")]),
            PaneSnapshot(id: 2, focusedAt: 2, tabs: [settings]),
            PaneSnapshot(id: 3, focusedAt: 3, tabs: [TabSnapshot(surface: 3, kind: .browser, title: "PR", url: "https://github.com")]),
        ]
        let layout = LayoutNode.split(id: nil, resourceID: nil, direction: .right, ratio: 0.5, a: .leaf(1),
                                      b: .split(id: nil, resourceID: nil, direction: .right, ratio: 0.5, a: .leaf(2), b: .leaf(3)))
        store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "workspace-3",
                                                                        screens: [ScreenSnapshot(id: 1, layout: layout, panes: panes)])]))
        let workspace = try #require(store.workspaces.first)
        #expect(SidebarMapping.shared.workTab(workspace, selectedTab: { _ in nil })?.title == "a")
    }

    @Test func aPageInASplitYieldsToTheLastFocusedWork() throws {
        let laterB = try Self.workspace(a: 1, b: 2, page: 3)
        #expect(SidebarMapping.shared.frontTab(laterB, selectedTab: { _ in nil })?.kind == .browser)
        #expect(SidebarMapping.shared.workTab(laterB, selectedTab: { _ in nil })?.title == "b")
        let laterA = try Self.workspace(a: 2, b: 1, page: 3)
        #expect(SidebarMapping.shared.workTab(laterA, selectedTab: { _ in nil })?.title == "a")
    }
}
