import CmuxNextIcons
import CmuxNextDaemon
import CmuxNextTabs
import Testing
@testable import CmuxNextBridge

/// A conversation tab rides a frontend browser record whose title is the
/// blank page's address (conversation-tabs-v1): the strip names it with the
/// caller's title and a conversation symbol, never "about:blank" with a
/// terminal icon (homenat7 snapshot).
@MainActor
struct ConversationTabItemTests {
    @Test func aConversationTabShowsItsTitleAndAConversationSymbol() throws {
        let tab = TabSnapshot(surface: 5, kind: .conversation, title: "about:blank", url: "about:blank")
        let pane = PaneSnapshot(id: 3, tabs: [tab])
        let workspace = WorkspaceSnapshot(id: 1, key: WorkspaceKey(rawValue: "0b6c4a52-6d3f-4c55-9d53-8f1f4e0f1a02"), name: "Home",
                                          screens: [ScreenSnapshot(id: 4, layout: .leaf(3), panes: [pane])])
        let store = DaemonStore()
        store.apply(snapshot: DaemonTree(workspaceRevision: 1, workspaces: [workspace]))
        let model = try #require(store.workspaces.first?.screens.first?.panes.first?.tabs.first)
        let item = TabItemMapping.shared.item(model, fallbackTitle: "Chief")
        #expect(item.title == "Chief")
        #expect(item.icon == .icon(.agentChat))
        #expect(item.subtitle == nil)
    }

    /// A tab still on the New Tab page draws the registry's new-tab icon, so
    /// it is told apart from an Agent chat tab by more than its title.
    @Test func aNewTabPageTabDrawsTheNewTabIcon() throws {
        let tab = TabSnapshot(surface: 5, kind: .conversation, title: "about:blank", url: "about:blank")
        let pane = PaneSnapshot(id: 3, tabs: [tab])
        let workspace = WorkspaceSnapshot(id: 1, key: WorkspaceKey(rawValue: "0b6c4a52-6d3f-4c55-9d53-8f1f4e0f1a02"), name: "Home",
                                          screens: [ScreenSnapshot(id: 4, layout: .leaf(3), panes: [pane])])
        let store = DaemonStore()
        store.apply(snapshot: DaemonTree(workspaceRevision: 1, workspaces: [workspace]))
        let model = try #require(store.workspaces.first?.screens.first?.panes.first?.tabs.first)
        let page = TabItemMapping.shared.item(model, fallbackTitle: "New Tab", isNewTabPage: true)
        let chat = TabItemMapping.shared.item(model, fallbackTitle: "Agent")
        #expect(page.icon == .icon(.tabNew))
        #expect(chat.icon == .icon(.agentChat))
        #expect(page.icon != chat.icon)
    }
}
