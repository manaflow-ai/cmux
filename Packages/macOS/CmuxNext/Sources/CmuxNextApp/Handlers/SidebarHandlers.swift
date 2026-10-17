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
            let panes = [focused].compactMap { $0 } + (context.services.windows.active?.content?.panes.values.map { $0 } ?? [])
            guard let view = panes.lazy.compactMap({ $0.currentTabKey.flatMap(tabs.existingView) }).first else {
                return context.refuse(RefusalStrings.needsAppCapability("right-sidebar"))
            }
            view.toggleSideColumn()
        })
    }
}
