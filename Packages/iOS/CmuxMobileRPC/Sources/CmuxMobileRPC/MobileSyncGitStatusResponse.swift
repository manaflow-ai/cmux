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
    /// Whether the host omitted untracked files beyond its processing cap.
    public let truncatedUntracked: Bool

    private enum CodingKeys: String, CodingKey {
        case repoRoot = "repo_root"
        case baseline
        case files
        case totalAdditions = "total_additions"
        case totalDeletions = "total_deletions"
        case truncatedUntracked = "truncated_untracked"
    }

    /// Decodes the status response, treating the additive truncation field as
    /// false when connected to an older host.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        repoRoot = try container.decode(String.self, forKey: .repoRoot)
        baseline = try container.decode(String.self, forKey: .baseline)
        files = try container.decode([MobileSyncGitStatusFile].self, forKey: .files)
        totalAdditions = try container.decode(Int.self, forKey: .totalAdditions)
        totalDeletions = try container.decode(Int.self, forKey: .totalDeletions)
        truncatedUntracked = try container.decodeIfPresent(Bool.self, forKey: .truncatedUntracked) ?? false
    }

    /// Decodes a workspace Git status response from raw JSON data.
    /// - Parameter data: The RPC result payload.
    /// - Returns: The decoded response.
    /// - Throws: A decoding error if the payload is malformed.
    public static func decode(_ data: Data) throws -> MobileSyncGitStatusResponse {
        try JSONDecoder().decode(Self.self, from: data)
    }
}
