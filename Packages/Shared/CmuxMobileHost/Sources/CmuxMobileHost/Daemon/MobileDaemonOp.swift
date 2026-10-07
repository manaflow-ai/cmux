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
    /// Files the workspace in `group` at `index` among that section's other
    /// members (`workspace.move`, E3).
    case moveWorkspace(workspace: String, group: MobileGroupPlacement, index: Int)
    /// Renames a sidebar group (`workspace.group.rename`).
    case renameGroup(group: String, name: String)
    /// Sets or clears the workspace's color and icon (`workspace.customize`).
    case customizeWorkspace(workspace: String, color: MobileFieldChange, icon: MobileFieldChange)
    case createWorkspace(name: String?)
    case createTab(workspace: String, pane: String?, kind: MobileTab.Kind, url: String?)
}
