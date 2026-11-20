/// How a new Cloud workspace picked its machine.
public enum CloudWorkspaceMachineChoice: String, Sendable, CaseIterable {
    /// New Cloud Workspace chose the window's last or first machine.
    case resolved
    /// The user picked the machine (its row, context menu, or palette entry).
    case explicit
}
