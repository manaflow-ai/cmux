public import Foundation

/// Typed decoder for the workspace Git status RPC result.
public struct MobileSyncGitStatusResponse: Decodable, Sendable {
    /// The absolute repository root reported by the Mac host.
    public let repoRoot: String
    /// The baseline identifier, currently `worktree`.
    public let baseline: String
    /// Changed files in Git porcelain order.
    public let files: [MobileSyncGitStatusFile]
    /// Added lines summed across non-binary files.
    public let totalAdditions: Int
    /// Deleted lines summed across non-binary files.
    public let totalDeletions: Int

    private enum CodingKeys: String, CodingKey {
        case repoRoot = "repo_root"
        case baseline
        case files
        case totalAdditions = "total_additions"
        case totalDeletions = "total_deletions"
    }

    /// Decodes a workspace Git status response from raw JSON data.
    /// - Parameter data: The RPC result payload.
    /// - Returns: The decoded response.
    /// - Throws: A decoding error if the payload is malformed.
    public static func decode(_ data: Data) throws -> MobileSyncGitStatusResponse {
        try JSONDecoder().decode(Self.self, from: data)
    }
}
