public import CmuxNextDaemon

/// Whether launch gives the tree its first workspace (`WindowManager.restore`, `FirstWorkspaceLaunch`).
public enum FirstWorkspace {
    /// The Home workspace a first launch lands on (`HomeTunables.launchIntoHome`, `FirstWorkspaceLaunch`),
    /// or nil to make a New Tab workspace: the switch is off, Home is classic, or Home has no workspace yet.
    public static func landing(launchIntoHome: Bool, classic: Bool, home: String?) -> String? {
        launchIntoHome && !classic ? home : nil
    }

    /// A tree with no workspace of the user's own gets one at launch.
    /// Leftover incognito and ephemeral workspaces do not count, nor does
    /// the store's home workspace, which exists from the first connect
    /// (`HomeService.ensureHomeWorkspace`) and holds only the Chief tab.
    /// `home` is the workspace `ensure_home` named: Home even while the tree
    /// does not report its kind yet (a fresh store's first snapshot).
    public static func isNeeded(_ workspaces: [WorkspaceModel], leftover: [String], home: ResourceID? = nil) -> Bool {
        !workspaces.contains { workspace in
            !leftover.contains(workspace.id) && !workspace.ephemeral && workspace.kind != "home"
                && (home == nil || workspace.resourceID != home)
        }
    }
}

