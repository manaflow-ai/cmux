import CmuxNextActions

/// Sidebar actions (category `sidebar`) beyond `toggleSidebar` (bound in
/// `AppActions`). cmux-next has no right sidebar or file explorer yet (the session vault is
/// `VaultHandlers`; minimal mode is `SidebarMinimalToggle`), so these report the missing
/// capability instead of doing nothing. The checklist actions are `WorkspaceChecklistHandlers`.
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
            ("match-terminal-background", ["palette.toggleMatchTerminalBackground"]),
        ]
        for (feature, ids) in features {
            for id in ids { registry.bindUnavailable([id], ActionFailure.needsAppCapability(feature)) }
        }
    }
}
