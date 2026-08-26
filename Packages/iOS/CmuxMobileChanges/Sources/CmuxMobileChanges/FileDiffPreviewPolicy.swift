/// Selects which binary revision an inline diff page initially displays.
public struct FileDiffPreviewPolicy: Sendable, Equatable {
    /// Revision displayed when the binary page first appears.
    public let defaultRevision: FileDiffPreviewRevision
    /// Whether the page offers both base and current revisions.
    public let allowsRevisionSelection: Bool

    /// Creates the binary-preview policy for a Git change kind.
    /// - Parameter kind: File change category used to resolve available revisions.
    public init(kind: FileChangeKind) {
        switch kind {
        case .modified, .renamed:
            defaultRevision = .current
            allowsRevisionSelection = true
        case .deleted:
            defaultRevision = .base
            allowsRevisionSelection = false
        case .added, .untracked, .unknown:
            defaultRevision = .current
            allowsRevisionSelection = false
        }
    }
}
