import CmuxNextActions
import CmuxNextAgentPane

/// Sidebar actions (category `sidebar`) beyond `toggleSidebar` (bound in
/// `AppActions`). cmux-next has no right sidebar, file explorer or session
/// vault yet (minimal mode is `SidebarMinimalToggle`), and the daemon has no checklist records, so
/// these report the missing capability instead of doing nothing.
enum SidebarHandlers {
    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        let features: [(String, [ActionID])] = [
            ("right-sidebar", [
                "toggleRightSidebar", "focusRightSidebar", "switchRightSidebarToFiles", "switchRightSidebarToFind",
                "switchRightSidebarToSessions", "switchRightSidebarToFeed", "switchRightSidebarToDock",
                "switchRightSidebarToMachines",
            ]),
            ("file-explorer", [
                "fileExplorerOpenSelection", "fileExplorerOpenSelectionFinderAlias", "fileExplorerOpenInCmux",
                "fileExplorerReveal", "fileExplorerCopyPath", "fileExplorerCopyRelativePath", "fileExplorerOpenWith",
            ]),
            ("session-vault", [
                "vaultFocusSession", "vaultOpenSession", "vaultResumeInNewWorkspace", "vaultCopyResumeCommand",
                "vaultOpenPullRequest",
            ]),
            ("match-terminal-background", ["palette.toggleMatchTerminalBackground"]),
        ]
        for (feature, ids) in features {
            for id in ids where id != "toggleRightSidebar" {
                registry.bindUnavailable([id], ActionFailure.needsAppCapability(feature))
            }
        }
        bindSideColumn(into: registry, context: context)
        let checklist: [ActionID] = [
            "checklistEditItem", "checklistMarkInProgress", "checklistCompleteItem", "checklistRemoveItem",
            "checklistOpenAsPane", "checklistAttachImages",
        ]
        for id in checklist {
            registry.bindUnavailable([id], ActionFailure.needsDaemonCapability("workspace-checklist-v1"))
        }
    }

    /// Toggle Right Sidebar (Opt-Cmd-B) with Debug Settings `agentChat.sideColumn` (Lucas 2026-10-17):
    /// the agent chat's side column, the panes beside it. The chat's own New tab / Hide tabs runs it
    /// (AgentChatSplitToggles.sideTabs): beside a lone chat a New Tab page opens in a column on its
    /// right; with panes beside the chat they hide (the chat zooms, closing nothing) and show again.
    /// The focused chat, else a chat showing in the window, takes it. Off, it reports that cmux-next
    /// has no right sidebar, as before; the toggle is read on every press, so no relaunch is needed.
    private static func bindSideColumn(into registry: ActionRegistry, context: AppActionContext) {
        let off: @MainActor () -> String? = {
            AgentPaneTunables.sideColumn.value ? nil : RefusalStrings.needsAppCapability("right-sidebar")
        }
        registry.bind("toggleRightSidebar", unavailable: off, invoke: { invocation in
            let tabs = context.services.agentTabs
            let focused = context.scope(invocation).pane
            // A chat's own view: never a New Tab page (the side column's tiles), which has no column to toggle.
            let chat = { (pane: PaneController) in
                pane.currentTabKey.flatMap { tabs.isNewTabPage($0) ? nil : tabs.existingView($0) }
            }
            if let focused, let view = chat(focused) { return view.toggleSideColumn() }
            // Focus beside a chat (a terminal, the column's tiles): the nearest chat on its left, else
            // the leftmost on screen, by where the panes sit, never the window's dictionary order.
            let left = { (pane: PaneController) in pane.view.convert(pane.view.bounds, to: nil).minX }
            let chats = (context.services.windows.active?.content?.panes.values.map { $0 } ?? [])
                .filter { chat($0) != nil }.sorted { left($0) < left($1) }
            let edge = focused.map(left) ?? .greatestFiniteMagnitude
            guard let pane = chats.last(where: { left($0) < edge }) ?? chats.first, let view = chat(pane) else {
                return context.refuse(RefusalStrings.needsAppCapability("right-sidebar"))
            }
            view.toggleSideColumn()
        })
    }
}
