import CmuxNextActions

/// Sidebar actions (category `sidebar`) beyond `toggleSidebar` (bound in
/// `AppActions`). cmux-next has no right sidebar, file explorer, session
/// vault, or minimal mode yet, and the daemon has no checklist records, so
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
            ("minimal-mode", ["palette.enableMinimalMode", "palette.disableMinimalMode"]),
            ("match-terminal-background", ["palette.toggleMatchTerminalBackground"]),
        ]
        for (feature, ids) in features {
            for id in ids { registry.bindUnavailable([id], ActionFailure.needsAppCapability(feature)) }
        }
        let checklist: [ActionID] = [
            "checklistEditItem", "checklistMarkInProgress", "checklistCompleteItem", "checklistRemoveItem",
            "checklistOpenAsPane", "checklistAttachImages",
        ]
        for id in checklist {
            registry.bindUnavailable([id], ActionFailure.needsDaemonCapability("workspace-checklist-v1"))
        }
    }
}
