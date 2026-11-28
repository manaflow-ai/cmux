import CmuxNextDaemon

/// Whether launch gives the tree its first workspace (`WindowManager.restore`).
enum FirstWorkspace {
    /// A tree with no workspace of the user's own gets one at launch.
    /// Leftover incognito and ephemeral workspaces do not count, nor does
    /// the store's home workspace, which exists from the first connect
    /// (`HomeService.ensureHomeWorkspace`) and holds only the Chief tab.
    static func isNeeded(_ workspaces: [WorkspaceModel], leftover: [String]) -> Bool {
        !workspaces.contains { !leftover.contains($0.id) && !$0.ephemeral && $0.kind != "home" }
    }
}
