public import CmuxMobileRPC

/// The semantic kind of a node in the changed-file tree.
public enum DiffTreeNodeKind: Sendable, Equatable {
    /// A directory, possibly representing a collapsed single-child chain.
    case directory
    /// A changed file with its Git status.
    case file(MobileDiffFileStatus)
}
