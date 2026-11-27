/// A repository revision available to workspace-changes content reads.
public enum WorkspaceChangesFileRevision: String, Sendable, Equatable {
    /// The file currently present in the working tree.
    case current
    /// The file blob at the resolved workspace-changes comparison base.
    case base
}
