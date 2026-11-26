/// A changed file revision available from the connected Mac.
public enum WorkspaceChangesFileRevision: String, Sendable, Equatable {
    /// The file currently present in the working tree.
    case current
    /// The file blob at the workspace changes comparison base.
    case base
}
