#if os(iOS)
import CmuxMobileModel
import Foundation

/// Workspace and tab changes go to the Mac they belong to, over that Mac's
/// own link (each `MacSession` has its `LiveWorkspaceCreationBackend`). A Mac
/// with no session answers through the idle stand-in, which says it is not
/// connected.
@MainActor
public final class MultiMacWorkspaceBackend: WorkspaceCreationBackend, WorkspaceArrangementBackend, NotificationClearing, WorkspaceGroupBackend,
    AgentChatsBackend, WorkspacePaneBackend {
    private weak var coordinator: LiveCoordinator?

    public init(coordinator: LiveCoordinator) {
        self.coordinator = coordinator
    }

    /// The backend of `macID`'s session; nil without a coordinator.
    private func on(_ macID: String) -> LiveWorkspaceCreationBackend? {
        guard let coordinator else { return nil }
        return coordinator.session(macID: macID)?.creation ?? coordinator.idleSession.creation
    }

    private func backend(_ macID: String) throws -> LiveWorkspaceCreationBackend {
        guard let backend = on(macID) else { throw WorkspaceCreationError("Not connected to a Mac") }
        // A change to a Mac whose link closed (idle) opens it again.
        if coordinator?.session(macID: macID)?.link.target == nil { coordinator?.touch(macID) }
        return backend
    }

    // MARK: WorkspaceCreationBackend

    public func canCreate(on macID: String) -> Bool { on(macID)?.canCreate(on: macID) ?? false }
    public func options(on macID: String) -> WorkspaceCreationOptions {
        on(macID)?.options(on: macID) ?? WorkspaceCreationOptions(directories: false, agents: [], browser: false, cloneFromGit: false,
                                                                   tapUsesLastDirectory: false)
    }
    public func create(_ request: NewWorkspaceRequest, placeholder: Workspace) async throws -> Workspace {
        try await backend(request.macID).create(request, placeholder: placeholder)
    }
    public func canManage(on macID: String) -> Bool { on(macID)?.canManage(on: macID) ?? false }
    public func rename(_ workspace: Workspace, to title: String) async throws {
        try await backend(workspace.macID).rename(workspace, to: title)
    }
    public func close(_ workspace: Workspace) async throws { try await backend(workspace.macID).close(workspace) }
    public func duplicate(_ workspace: Workspace) async throws -> Workspace { try await backend(workspace.macID).duplicate(workspace) }
    public func tabKinds(on macID: String) -> [NewTabKind] { on(macID)?.tabKinds(on: macID) ?? [] }
    public func unavailableTabKinds(on macID: String) -> [(kind: NewTabKind, reason: String)] {
        on(macID)?.unavailableTabKinds(on: macID) ?? []
    }
    public func agentCatalog(on macID: String) async throws -> AgentCatalog { try await backend(macID).agentCatalog(on: macID) }
    public func createTab(_ kind: NewTabKind, in workspace: Workspace) async throws -> WorkspaceTab {
        try await backend(workspace.macID).createTab(kind, in: workspace)
    }
    public func closeTab(_ tab: WorkspaceTab, in workspace: Workspace) async throws {
        try await backend(workspace.macID).closeTab(tab, in: workspace)
    }
    public func runningPrograms(of tabs: [WorkspaceTab], in workspace: Workspace) async -> [String] {
        await on(workspace.macID)?.runningPrograms(of: tabs, in: workspace) ?? []
    }
    public func canEditTabs(on macID: String) -> Bool { on(macID)?.canEditTabs(on: macID) ?? false }
    public func renameTab(_ tab: WorkspaceTab, in workspace: Workspace, to title: String) async throws {
        try await backend(workspace.macID).renameTab(tab, in: workspace, to: title)
    }
    public func duplicateTab(_ tab: WorkspaceTab, in workspace: Workspace) async throws -> WorkspaceTab {
        try await backend(workspace.macID).duplicateTab(tab, in: workspace)
    }
    public func openBrowserTab(_ url: URL, besides tab: WorkspaceTab, in workspace: Workspace) async throws -> WorkspaceTab {
        try await backend(workspace.macID).openBrowserTab(url, besides: tab, in: workspace)
    }
    public func openLink(_ url: URL, besides tab: WorkspaceTab, in workspace: Workspace) async throws -> WorkspaceTab {
        try await backend(workspace.macID).openLink(url, besides: tab, in: workspace)
    }
    public func moveTab(_ tab: WorkspaceTab, to target: WorkspaceTab, in workspace: Workspace) async throws {
        try await backend(workspace.macID).moveTab(tab, to: target, in: workspace)
    }
    public func moveTab(_ tab: WorkspaceTab, from workspace: Workspace, toWorkspace destination: Workspace?) async throws -> Workspace? {
        try await backend(workspace.macID).moveTab(tab, from: workspace, toWorkspace: destination)
    }
    public func restartShell(_ tab: WorkspaceTab, in workspace: Workspace) async throws {
        try await backend(workspace.macID).restartShell(tab, in: workspace)
    }
    public func setTabPinned(_ tab: WorkspaceTab, in workspace: Workspace, pinned: Bool) async throws {
        try await backend(workspace.macID).setTabPinned(tab, in: workspace, pinned: pinned)
    }
    public func editTabGroup(_ edit: TabGroupEdit, tab: WorkspaceTab, in workspace: Workspace) async throws {
        try await backend(workspace.macID).editTabGroup(edit, tab: tab, in: workspace)
    }
    public func forkAgentChat(_ tab: WorkspaceTab, in workspace: Workspace) async throws -> WorkspaceTab {
        try await backend(workspace.macID).forkAgentChat(tab, in: workspace)
    }
    public func archiveAgentChat(_ tab: WorkspaceTab, in workspace: Workspace) async throws {
        try await backend(workspace.macID).archiveAgentChat(tab, in: workspace)
    }
    public func savedTabGroups(on macID: String) async throws -> [SavedTabGroup] { try await backend(macID).savedTabGroups(on: macID) }
    public func reopenSavedTabGroup(_ saved: SavedTabGroup, besides tab: WorkspaceTab, in workspace: Workspace) async throws {
        try await backend(workspace.macID).reopenSavedTabGroup(saved, besides: tab, in: workspace)
    }
    public func deleteSavedTabGroup(_ saved: SavedTabGroup, on macID: String) async throws {
        try await backend(macID).deleteSavedTabGroup(saved, on: macID)
    }
    public func canMoveTabGroup(of tab: WorkspaceTab, forward: Bool, in workspace: Workspace) -> Bool {
        on(workspace.macID)?.canMoveTabGroup(of: tab, forward: forward, in: workspace) ?? false
    }
    public func newTabInGroup(of tab: WorkspaceTab, in workspace: Workspace) async throws -> WorkspaceTab {
        try await backend(workspace.macID).newTabInGroup(of: tab, in: workspace)
    }
    public func selectScreen(_ screen: MacScreen, in workspace: Workspace) async throws {
        try await backend(workspace.macID).selectScreen(screen, in: workspace)
    }
    public func newScreen(in workspace: Workspace) async throws -> WorkspaceTab {
        try await backend(workspace.macID).newScreen(in: workspace)
    }
    public func renameScreen(_ screen: MacScreen, in workspace: Workspace, to name: String) async throws {
        try await backend(workspace.macID).renameScreen(screen, in: workspace, to: name)
    }
    public func closeScreen(_ screen: MacScreen, in workspace: Workspace) async throws {
        try await backend(workspace.macID).closeScreen(screen, in: workspace)
    }

    // MARK: WorkspacePaneBackend

    public func canEditPanes(on macID: String) -> Bool { on(macID)?.canEditPanes(on: macID) ?? false }
    public func split(_ pane: Int, _ direction: PaneSplit, in workspace: Workspace) async throws -> WorkspaceTab {
        try await backend(workspace.macID).split(pane, direction, in: workspace)
    }
    public func newPane(from pane: Int, column: Bool, in workspace: Workspace) async throws -> WorkspaceTab {
        try await backend(workspace.macID).newPane(from: pane, column: column, in: workspace)
    }
    public func toggleZoom(_ pane: Int, in workspace: Workspace) async throws {
        try await backend(workspace.macID).toggleZoom(pane, in: workspace)
    }
    public func swap(_ pane: Int, _ direction: PaneSwap, in workspace: Workspace) async throws {
        try await backend(workspace.macID).swap(pane, direction, in: workspace)
    }
    public func renamePane(_ pane: Int, to name: String, in workspace: Workspace) async throws {
        try await backend(workspace.macID).renamePane(pane, to: name, in: workspace)
    }
    public func closePane(_ pane: Int, in workspace: Workspace) async throws {
        try await backend(workspace.macID).closePane(pane, in: workspace)
    }
    public func equalizeSplits(in workspace: Workspace) async throws -> Int {
        try await backend(workspace.macID).equalizeSplits(in: workspace)
    }
    public func undoLayout(in workspace: Workspace, confirming confirmation: LayoutUndoConfirmation?) async throws -> LayoutUndoOutcome {
        try await backend(workspace.macID).undoLayout(in: workspace, confirming: confirmation)
    }
    public func moveTab(_ tab: WorkspaceTab, toNewSplit edge: TabSplitEdge, in workspace: Workspace) async throws {
        try await backend(workspace.macID).moveTab(tab, toNewSplit: edge, in: workspace)
    }
    public func moveTabToNewColumn(_ tab: WorkspaceTab, in workspace: Workspace) async throws {
        try await backend(workspace.macID).moveTabToNewColumn(tab, in: workspace)
    }
    public func moveTab(_ tab: WorkspaceTab, toPane pane: Int, in workspace: Workspace) async throws {
        try await backend(workspace.macID).moveTab(tab, toPane: pane, in: workspace)
    }
    public func forkAgentChat(_ tab: WorkspaceTab, to destination: ChatForkDestination, in workspace: Workspace) async throws -> WorkspaceTab {
        try await backend(workspace.macID).forkAgentChat(tab, to: destination, in: workspace)
    }

    // MARK: WorkspaceArrangementBackend

    public func canArrange(on macID: String) -> Bool { on(macID)?.canArrange(on: macID) ?? false }
    public func setPinned(_ workspace: Workspace, _ pinned: Bool) async throws {
        try await backend(workspace.macID).setPinned(workspace, pinned)
    }
    public func setColor(_ workspace: Workspace, _ color: WorkspaceColor?) async throws {
        try await backend(workspace.macID).setColor(workspace, color)
    }
    public func move(_ workspace: Workspace, by offset: Int, among visible: [Workspace]) async throws {
        try await backend(workspace.macID).move(workspace, by: offset, among: visible)
    }
    public func setUnread(_ workspace: Workspace, _ unread: Bool) async throws {
        try await backend(workspace.macID).setUnread(workspace, unread)
    }
    public func setIcon(_ workspace: Workspace, _ icon: String?) async throws {
        try await backend(workspace.macID).setIcon(workspace, icon)
    }
    public func clearName(_ workspace: Workspace) async throws { try await backend(workspace.macID).clearName(workspace) }
    public func place(_ workspace: Workspace, next anchor: Workspace, after: Bool) async throws {
        try await backend(workspace.macID).place(workspace, next: anchor, after: after)
    }

    // MARK: NotificationClearing

    public func canClearNotifications(on macID: String) -> Bool { on(macID)?.canClearNotifications(on: macID) ?? false }
    public func clearAllNotifications(on macID: String) async throws {
        try await backend(macID).clearAllNotifications(on: macID)
        coordinator?.session(macID: macID)?.terminalFeed.cleared()
    }
    public func markAllNotificationsRead(on macID: String) async throws -> Int {
        try await backend(macID).markAllNotificationsRead(on: macID)
    }

    // MARK: AgentChatsBackend

    public func canListAgentChats(on macID: String) -> Bool { on(macID)?.canListAgentChats(on: macID) ?? false }
    public func agentChats(on macID: String, cursor: String?) async throws -> AgentChatPage {
        try await backend(macID).agentChats(on: macID, cursor: cursor)
    }
    public func openAgentChat(_ chat: AgentChatListing, in workspace: Workspace) async throws -> WorkspaceTab {
        try await backend(workspace.macID).openAgentChat(chat, in: workspace)
    }
    public func openAgentChatInNewWorkspace(_ chat: AgentChatListing, on macID: String) async throws -> Workspace {
        try await backend(macID).openAgentChatInNewWorkspace(chat, on: macID)
    }
    public func setAgentChatArchived(_ chat: AgentChatListing, archived: Bool, on macID: String) async throws -> AgentChatListing {
        try await backend(macID).setAgentChatArchived(chat, archived: archived, on: macID)
    }
    public func openChatFolderInTerminal(_ tab: WorkspaceTab, in workspace: Workspace) async throws -> WorkspaceTab {
        try await backend(workspace.macID).openChatFolderInTerminal(tab, in: workspace)
    }

    // MARK: WorkspaceGroupBackend

    public func groups(on macID: String) -> [MacWorkspaceGroup] { on(macID)?.groups(on: macID) ?? [] }
    public func place(_ workspace: Workspace, in group: MacWorkspaceGroup?) async throws {
        try await backend(workspace.macID).place(workspace, in: group)
    }
    public func moveToNewGroup(_ workspace: Workspace, name: String, color: WorkspaceColor) async throws {
        try await backend(workspace.macID).moveToNewGroup(workspace, name: name, color: color)
    }
    public func updateGroup(_ group: MacWorkspaceGroup, on macID: String, name: String?, color: WorkspaceColor?, collapsed: Bool?) async throws {
        try await backend(macID).updateGroup(group, on: macID, name: name, color: color, collapsed: collapsed)
    }
    public func deleteGroup(_ group: MacWorkspaceGroup, on macID: String) async throws {
        try await backend(macID).deleteGroup(group, on: macID)
    }
}
#endif
