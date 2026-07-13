import Foundation

/// A size-bounded collection of per-path unified diffs relative to `HEAD`.
public struct WorkspaceGitDiff: Equatable, Sendable {
    /// The baseline identifier, currently always `worktree`.
    public let baseline: String
    /// Concatenated unified patch text for included paths.
    public let patch: String
    /// Requested paths whose generated patch content is included.
    public let included: [String]
    /// Requested paths omitted after the next patch would cross the response cap.
    public let truncated: [String]
    /// Requested paths whose individual patch alone exceeds the response cap.
    public let tooLarge: [WorkspaceGitTooLargePath]

    /// Creates a size-bounded workspace diff response.
    /// - Parameters:
    ///   - baseline: The baseline identifier.
    ///   - patch: Concatenated unified patch text.
    ///   - included: Paths represented in `patch`.
    ///   - truncated: Paths omitted after cap enforcement stopped accumulation.
    ///   - tooLarge: Individually oversized paths.
    public init(
        baseline: String,
        patch: String,
        included: [String],
        truncated: [String],
        tooLarge: [WorkspaceGitTooLargePath]
    ) {
        self.baseline = baseline
        self.patch = patch
        self.included = included
        self.truncated = truncated
        self.tooLarge = tooLarge
    }
}
