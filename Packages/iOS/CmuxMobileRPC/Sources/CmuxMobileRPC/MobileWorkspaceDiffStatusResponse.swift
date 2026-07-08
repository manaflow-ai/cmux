public import Foundation

/// Typed decoder for the `mobile.workspace.diff_status` RPC result.
public struct MobileWorkspaceDiffStatusResponse: Decodable, Sendable {
    /// One changed file in the workspace repository.
    public struct File: Decodable, Sendable, Identifiable, Equatable {
        /// Stable row identity.
        public var id: String { oldPath.map { "\($0)->\(path)" } ?? path }
        /// New/current repository-relative path.
        public let path: String
        /// Old repository-relative path for renamed files.
        public let oldPath: String?
        /// File status (`A`, `M`, `D`, `R`, or `U`).
        public let status: String
        /// Added-line count, when reported by git.
        public let additions: Int?
        /// Deleted-line count, when reported by git.
        public let deletions: Int?

        private enum CodingKeys: String, CodingKey {
            case path
            case oldPath = "old_path"
            case status
            case additions
            case deletions
        }

        /// Decodes one changed file, tolerating absent optional fields from older
        /// or future Mac builds.
        /// - Parameter decoder: The decoder for the file payload.
        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            path = try container.decode(String.self, forKey: .path)
            oldPath = try container.decodeIfPresent(String.self, forKey: .oldPath)
            status = try container.decode(String.self, forKey: .status)
            additions = try container.decodeIfPresent(Int.self, forKey: .additions)
            deletions = try container.decodeIfPresent(Int.self, forKey: .deletions)
        }
    }

    /// Repository root on the paired Mac.
    public let repoRoot: String
    /// Changed files in display order.
    public let files: [File]
    /// Whether the Mac cut the list off at its output bounds (huge change
    /// sets); absent from older Mac builds.
    public let truncated: Bool

    private enum CodingKeys: String, CodingKey {
        case repoRoot = "repo_root"
        case files
        case truncated
    }

    /// Decodes a diff-status response.
    /// - Parameter decoder: The decoder for the RPC result payload.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        repoRoot = try container.decodeIfPresent(String.self, forKey: .repoRoot) ?? ""
        files = try container.decodeIfPresent([File].self, forKey: .files) ?? []
        truncated = try container.decodeIfPresent(Bool.self, forKey: .truncated) ?? false
    }

    /// Decode a diff-status response from raw JSON data.
    /// - Parameter data: The RPC result payload.
    /// - Returns: The decoded response.
    public static func decode(_ data: Data) throws -> MobileWorkspaceDiffStatusResponse {
        try JSONDecoder().decode(Self.self, from: data)
    }
}
