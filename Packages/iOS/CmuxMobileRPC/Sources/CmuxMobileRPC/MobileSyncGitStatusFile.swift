import Foundation

/// One changed file decoded from a workspace Git status response.
public struct MobileSyncGitStatusFile: Decodable, Sendable {
    /// The repository-relative current path.
    public let path: String
    /// The repository-relative prior path for a rename, otherwise `nil`.
    public let oldPath: String?
    /// The normalized status code: `M`, `A`, `D`, or `R`.
    public let status: String
    /// The number of added lines, or zero for binary files.
    public let additions: Int
    /// The number of deleted lines, or zero for binary files.
    public let deletions: Int
    /// Whether Git classified the file as binary.
    public let binary: Bool
    /// Whether the path is untracked.
    public let untracked: Bool

    private enum CodingKeys: String, CodingKey {
        case path
        case oldPath = "old_path"
        case status
        case additions
        case deletions
        case binary
        case untracked
    }
}
