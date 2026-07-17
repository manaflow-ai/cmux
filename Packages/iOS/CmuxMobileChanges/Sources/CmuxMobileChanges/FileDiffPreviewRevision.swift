/// A changed-file revision selected from the binary diff card.
public enum FileDiffPreviewRevision: String, Sendable, Equatable, Hashable {
    /// The current working-tree file.
    case current
    /// The file at the changes comparison base.
    case base
}
