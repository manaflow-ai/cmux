/// One changed file in a workspace diff-status response.
public struct MobileWorkspaceDiffStatusFile: Decodable, Sendable, Identifiable, Equatable {
    /// Stable row identity.
    public var id: String { path }
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
    /// Opaque repository-state identity required by the file request.
    public let snapshotToken: String

    private enum CodingKeys: String, CodingKey {
        case path
        case oldPath = "old_path"
        case status
        case additions
        case deletions
        case snapshotToken = "snapshot_token"
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
        snapshotToken = try container.decode(String.self, forKey: .snapshotToken)
        guard !snapshotToken.isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .snapshotToken,
                in: container,
                debugDescription: "Diff snapshot token must not be empty"
            )
        }
    }
}
