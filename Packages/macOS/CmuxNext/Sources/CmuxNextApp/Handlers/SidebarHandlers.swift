import CmuxNextActions
import CmuxNextAgentPane

/// Sidebar actions (category `sidebar`) beyond `toggleSidebar` (bound in
/// `AppActions`). cmux-next has no right sidebar, file explorer or session
/// vault yet (minimal mode is `SidebarMinimalToggle`), so these report the missing capability
/// instead of doing nothing. The checklist actions are `WorkspaceChecklistHandlers`.
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
            for id in ids where id != "toggleRightSidebar" { registry.bindUnavailable([id], ActionFailure.needsAppCapability(feature)) }
        }
        AgentChatSideColumn().bind(into: registry, unavailable: { RefusalStrings.needsAppCapability("right-sidebar") }, focused: { context.scope($0).pane }, panes: { context.services.windows.active?.content?.panes.values.map { $0 } ?? [] },
                                   chat: { $0.currentTabKey.flatMap { context.services.agentTabs.isNewTabPage($0) ? nil : context.services.agentTabs.existingView($0) } }, left: { $0.view.convert($0.view.bounds, to: nil).minX }, refuse: { context.refuse($0) })
    }
}
