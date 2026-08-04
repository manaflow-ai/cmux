public import Foundation

/// Typed decoder for the `mobile.workspace.changes.files` RPC result.
public struct MobileWorkspaceChangedFilesResponse: Decodable, Sendable {
    /// Change metadata for one repository-relative path.
    public struct File: Decodable, Sendable, Equatable {
        /// Current repository-relative path.
        public let path: String
        /// Previous repository-relative path for a rename.
        public let oldPath: String?
        /// File change category, including an unknown fallback for newer hosts.
        public let status: MobileWorkspaceChangeStatus
        /// Number of added lines, or zero for binary content.
        public let additions: Int
        /// Number of deleted lines, or zero for binary content.
        public let deletions: Int
        /// Whether Git identified the file as binary.
        public let isBinary: Bool
        /// Whether a host-side cap made the additions count partial.
        public let isApproximate: Bool?

        private enum CodingKeys: String, CodingKey {
            case path
            case oldPath = "old_path"
            case status
            case additions
            case deletions
            case isBinary = "is_binary"
            case isApproximate = "is_approximate"
        }

        /// Decodes one file entry with defaults for fields omitted by older hosts.
        /// The path is the entry's list identity, so it decodes strictly: an
        /// entry without one is malformed and must be omitted by the batch
        /// loop, not surfaced as an empty-path row with a colliding ID.
        /// - Parameter decoder: The decoder for one file object.
        /// - Throws: A decoding error when the path is missing or empty.
        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            path = try container.decode(String.self, forKey: .path)
            guard !path.isEmpty else {
                throw DecodingError.dataCorruptedError(
                    forKey: .path,
                    in: container,
                    debugDescription: "path must be a non-empty string"
                )
            }
            oldPath = (try? container.decodeIfPresent(String.self, forKey: .oldPath)) ?? nil
            let rawStatus = (try? container.decodeIfPresent(String.self, forKey: .status)) ?? ""
            status = MobileWorkspaceChangeStatus(rawValue: rawStatus) ?? .unknown
            additions = (try? container.decodeIfPresent(Int.self, forKey: .additions)) ?? 0
            deletions = (try? container.decodeIfPresent(Int.self, forKey: .deletions)) ?? 0
            isBinary = (try? container.decodeIfPresent(Bool.self, forKey: .isBinary)) ?? false
            isApproximate = try? container.decodeIfPresent(Bool.self, forKey: .isApproximate)
        }
    }

    /// Stable workspace identifier.
    public let workspaceID: String
    /// Absolute repository root.
    public let repoRoot: String
    /// Checked-out branch name, or `nil` for detached `HEAD`.
    public let branch: String?
    /// Default-branch reference used as the comparison base, when available.
    public let baseRef: String?
    /// Path-sorted changed files. Malformed entries are omitted individually.
    public let files: [File]
    /// Number of changed files before any host cap.
    public let filesChanged: Int
    /// Number of added lines before any host cap.
    public let additions: Int
    /// Number of deleted lines before any host cap.
    public let deletions: Int
    /// Whether the host omitted files because of its response cap.
    public let truncated: Bool

    private enum CodingKeys: String, CodingKey {
        case workspaceID = "workspace_id"
        case repoRoot = "repo_root"
        case branch
        case baseRef = "base_ref"
        case files
        case filesChanged = "files_changed"
        case additions
        case deletions
        case truncated
    }

    /// Decodes the file list leniently, preserving valid siblings when one entry
    /// is malformed.
    /// - Parameter decoder: The decoder for the RPC result payload.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        workspaceID = (try? container.decodeIfPresent(String.self, forKey: .workspaceID)) ?? ""
        repoRoot = (try? container.decodeIfPresent(String.self, forKey: .repoRoot)) ?? ""
        branch = (try? container.decodeIfPresent(String.self, forKey: .branch)) ?? nil
        baseRef = (try? container.decodeIfPresent(String.self, forKey: .baseRef)) ?? nil
        filesChanged = (try? container.decodeIfPresent(Int.self, forKey: .filesChanged)) ?? 0
        additions = (try? container.decodeIfPresent(Int.self, forKey: .additions)) ?? 0
        deletions = (try? container.decodeIfPresent(Int.self, forKey: .deletions)) ?? 0
        truncated = (try? container.decodeIfPresent(Bool.self, forKey: .truncated)) ?? false

        var decodedFiles: [File] = []
        if var entries = try? container.nestedUnkeyedContainer(forKey: .files) {
            while !entries.isAtEnd {
                guard let entryDecoder = try? entries.superDecoder() else { break }
                if let file = try? File(from: entryDecoder) {
                    decodedFiles.append(file)
                }
            }
        }
        files = decodedFiles
    }

    /// Decode a changed-files response from raw JSON data.
    /// - Parameter data: The RPC result payload.
    /// - Returns: The decoded response.
    /// - Throws: A decoding error if the payload is not a JSON object.
    public static func decode(_ data: Data) throws -> MobileWorkspaceChangedFilesResponse {
        try JSONDecoder().decode(Self.self, from: data)
    }
}
