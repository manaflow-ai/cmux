public import Foundation

/// Typed decoder for the `mobile.workspace.changes.file_diff` RPC result.
public struct MobileWorkspaceFileDiffResponse: Decodable, Sendable, Equatable {
    /// Current repository-relative path.
    public let path: String
    /// Previous repository-relative path for a rename.
    public let oldPath: String?
    /// File change category, including an unknown fallback for newer hosts.
    public let status: MobileWorkspaceChangeStatus
    /// Whether Git identified the file as binary.
    public let isBinary: Bool
    /// Number of added lines, or zero for binary content.
    public let additions: Int
    /// Number of deleted lines, or zero for binary content.
    public let deletions: Int
    /// Raw unified-diff text.
    public let unifiedDiff: String
    /// Whether the host omitted complete hunks because of its response cap.
    public let truncated: Bool
    /// Number of lines in the full diff, when reported by the host.
    public let diffTotalLines: Int?
    /// Size, timestamps, device, and inode fingerprint for the current working file.
    public let contentFingerprint: String?

    private enum CodingKeys: String, CodingKey {
        case path
        case oldPath = "old_path"
        case status
        case isBinary = "is_binary"
        case additions
        case deletions
        case unifiedDiff = "unified_diff"
        case truncated
        case diffTotalLines = "diff_total_lines"
        case contentFingerprint = "content_fingerprint"
    }

    /// Decodes the diff response with safe defaults for omitted fields.
    /// - Parameter decoder: The decoder for the RPC result payload.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        path = (try? container.decodeIfPresent(String.self, forKey: .path)) ?? ""
        oldPath = (try? container.decodeIfPresent(String.self, forKey: .oldPath)) ?? nil
        let rawStatus = (try? container.decodeIfPresent(String.self, forKey: .status)) ?? ""
        status = MobileWorkspaceChangeStatus(rawValue: rawStatus) ?? .unknown
        isBinary = (try? container.decodeIfPresent(Bool.self, forKey: .isBinary)) ?? false
        additions = (try? container.decodeIfPresent(Int.self, forKey: .additions)) ?? 0
        deletions = (try? container.decodeIfPresent(Int.self, forKey: .deletions)) ?? 0
        unifiedDiff = (try? container.decodeIfPresent(String.self, forKey: .unifiedDiff)) ?? ""
        truncated = (try? container.decodeIfPresent(Bool.self, forKey: .truncated)) ?? false
        diffTotalLines = try? container.decodeIfPresent(Int.self, forKey: .diffTotalLines)
        contentFingerprint = try? container.decodeIfPresent(String.self, forKey: .contentFingerprint)
    }

    /// Decode a file-diff response from raw JSON data.
    /// - Parameter data: The RPC result payload.
    /// - Returns: The decoded response.
    /// - Throws: A decoding error if the payload is not a JSON object.
    public static func decode(_ data: Data) throws -> MobileWorkspaceFileDiffResponse {
        try JSONDecoder().decode(Self.self, from: data)
    }
}
