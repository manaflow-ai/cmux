/// An op the policy validated. Spawning cases reach the daemon only when the
/// host configuration allows terminal spawn (b5-mac-host.md section 3), and
/// never carry a command, cwd or environment.
public enum MobileDaemonOp: Hashable, Sendable {
    case renameWorkspace(workspace: String, name: String)
    case closeTab(tab: String)
    /// Closes every tab of the workspace and removes it (`workspace.close`).
    case closeWorkspace(workspace: String)
    /// Clears unread on every tab of the workspace (`workspace.read`).
    case markWorkspaceRead(workspace: String)
    case createWorkspace(name: String?)
    case createTab(workspace: String, pane: String?, kind: MobileTab.Kind, url: String?)
}
