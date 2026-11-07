/// What the File Preview gutter shows for git: whether the file has a git
/// base at all, and which lines differ from it.
///
/// A tracked file reserves the stripe column even when nothing changed, so the
/// first edit does not widen the gutter and shift the text.
public struct FilePreviewGitGutterMarkers: Sendable, Equatable {
    /// A file with no git base: untracked, outside a repository, or too large.
    public static let untracked = FilePreviewGitGutterMarkers(isTracked: false, changes: [:])

    /// Whether the file has a git base to compare against.
    public let isTracked: Bool
    /// Changes keyed by 1-based line number. Empty when the file is untracked.
    public let changes: [Int: FilePreviewGitLineChange]

    /// Creates gutter markers.
    ///
    /// - Parameters:
    ///   - isTracked: Whether the file has a git base.
    ///   - changes: Changes keyed by 1-based line number. Ignored and stored
    ///     empty when `isTracked` is `false`.
    public init(isTracked: Bool, changes: [Int: FilePreviewGitLineChange]) {
        self.isTracked = isTracked
        self.changes = isTracked ? changes : [:]
    }
}
