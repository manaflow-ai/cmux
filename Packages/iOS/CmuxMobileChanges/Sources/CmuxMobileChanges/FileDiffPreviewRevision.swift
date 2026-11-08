/// A changed-file revision rendered by a binary diff preview.
public enum FileDiffPreviewRevision: String, Sendable, Equatable, Hashable {
    /// The current working-tree file.
    case current
    /// The file at the changes comparison base.
    case base
}
