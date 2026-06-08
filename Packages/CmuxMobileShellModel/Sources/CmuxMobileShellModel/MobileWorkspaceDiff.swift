import Foundation

/// A `Sendable` snapshot of a workspace's git diff, produced by the Mac for the
/// mobile read-only diff/file viewer.
///
/// `patch` is the unified-diff text the diff-viewer React bundle renders. An
/// empty patch is a valid result (the workspace has no changes, or its directory
/// is not a git repository) and drives the viewer's empty state. `truncated`
/// indicates the Mac capped an oversized patch, so the UI can surface a "diff
/// truncated" note.
public struct MobileWorkspaceDiff: Equatable, Sendable {
    /// The unified git diff patch text.
    public let patch: String
    /// A short label for the diff source (e.g. "git unstaged").
    public let sourceLabel: String?
    /// The resolved working directory the diff was produced from.
    public let currentDirectory: String?
    /// Whether the Mac truncated an oversized patch.
    public let truncated: Bool

    /// Creates a workspace diff snapshot.
    /// - Parameters:
    ///   - patch: The unified git diff patch text.
    ///   - sourceLabel: A short label for the diff source.
    ///   - currentDirectory: The resolved working directory.
    ///   - truncated: Whether the Mac truncated an oversized patch.
    public init(
        patch: String,
        sourceLabel: String? = nil,
        currentDirectory: String? = nil,
        truncated: Bool = false
    ) {
        self.patch = patch
        self.sourceLabel = sourceLabel
        self.currentDirectory = currentDirectory
        self.truncated = truncated
    }

    /// Whether the diff has no content to review.
    public var isEmpty: Bool {
        patch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
