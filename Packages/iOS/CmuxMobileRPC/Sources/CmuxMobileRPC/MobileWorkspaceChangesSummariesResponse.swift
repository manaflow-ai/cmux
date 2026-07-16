public import Foundation

/// Typed decoder for the `mobile.workspace.changes.summary` RPC result.
public struct MobileWorkspaceChangesSummariesResponse: Decodable, Sendable {
    /// Aggregate change metadata for one requested workspace.
    public struct Summary: Decodable, Sendable, Equatable {
        /// Stable workspace identifier.
        public let workspaceID: String
        /// Whether the workspace directory belongs to a Git repository.
        public let isRepository: Bool
        /// Absolute repository root, when the workspace is in a repository.
        public let repoRoot: String?
        /// Checked-out branch name, or `nil` for detached `HEAD`.
        public let branch: String?
        /// Default-branch reference used as the comparison base, when available.
        public let baseRef: String?
        /// Number of changed files.
        public let filesChanged: Int
        /// Number of added lines.
        public let additions: Int
        /// Number of deleted lines.
        public let deletions: Int

        private enum CodingKeys: String, CodingKey {
            case workspaceID = "workspace_id"
            case isRepository = "is_repo"
            case repoRoot = "repo_root"
            case branch
            case baseRef = "base_ref"
            case filesChanged = "files_changed"
            case additions
            case deletions
        }

        /// Decodes one summary leniently so fields added by newer hosts cannot
        /// make the surrounding batch unusable.
        /// - Parameter decoder: The decoder for one summary object.
        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            workspaceID = (try? container.decodeIfPresent(String.self, forKey: .workspaceID)) ?? ""
            isRepository = (try? container.decodeIfPresent(Bool.self, forKey: .isRepository)) ?? false
            repoRoot = (try? container.decodeIfPresent(String.self, forKey: .repoRoot)) ?? nil
            branch = (try? container.decodeIfPresent(String.self, forKey: .branch)) ?? nil
            baseRef = (try? container.decodeIfPresent(String.self, forKey: .baseRef)) ?? nil
            filesChanged = (try? container.decodeIfPresent(Int.self, forKey: .filesChanged)) ?? 0
            additions = (try? container.decodeIfPresent(Int.self, forKey: .additions)) ?? 0
            deletions = (try? container.decodeIfPresent(Int.self, forKey: .deletions)) ?? 0
        }
    }

    /// Per-workspace summaries. Malformed entries are omitted individually.
    public let summaries: [Summary]

    private enum CodingKeys: String, CodingKey {
        case summaries
    }

    /// Decodes the batch while dropping malformed summary entries instead of
    /// failing every requested workspace.
    /// - Parameter decoder: The decoder for the RPC result payload.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard var entries = try? container.nestedUnkeyedContainer(forKey: .summaries) else {
            summaries = []
            return
        }
        var decoded: [Summary] = []
        while !entries.isAtEnd {
            guard let entryDecoder = try? entries.superDecoder() else { break }
            if let summary = try? Summary(from: entryDecoder) {
                decoded.append(summary)
            }
        }
        summaries = decoded
    }

    /// Decode a summaries response from raw JSON data.
    /// - Parameter data: The RPC result payload.
    /// - Returns: The decoded response.
    /// - Throws: A decoding error if the payload is not a JSON object.
    public static func decode(_ data: Data) throws -> MobileWorkspaceChangesSummariesResponse {
        try JSONDecoder().decode(Self.self, from: data)
    }
}
