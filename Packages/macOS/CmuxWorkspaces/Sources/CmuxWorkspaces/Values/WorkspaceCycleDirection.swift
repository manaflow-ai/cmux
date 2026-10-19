/// The direction in which workspace cycling advances through an ordered set.
public enum WorkspaceCycleDirection: Sendable {
    /// Advances to the following workspace, wrapping to the first workspace.
    case next

    /// Advances to the preceding workspace, wrapping to the last workspace.
    case previous
}
