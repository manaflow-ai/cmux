import CmuxNextActions

/// Sidebar actions (category `sidebar`) beyond `toggleSidebar` (bound in
/// `AppActions`), the right sidebar (`RightSidebarHandlers`) and the session
/// vault (`VaultHandlers`). cmux-next has no file explorer yet (minimal mode
/// is `SidebarMinimalToggle`), so these report the missing capability instead
/// of doing nothing. The checklist actions are `WorkspaceChecklistHandlers`.
enum SidebarHandlers {
    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        let features: [(String, [ActionID])] = [
            // The right sidebar's Files and Find sections are the file explorer's (a123); the
            // other right sidebar actions are `RightSidebarHandlers`.
            ("right-sidebar", ["switchRightSidebarToFiles", "switchRightSidebarToFind"]),
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
