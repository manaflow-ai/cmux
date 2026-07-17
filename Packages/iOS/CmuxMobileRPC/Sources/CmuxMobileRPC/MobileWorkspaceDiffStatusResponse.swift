public import Foundation

/// Typed decoder for the `mobile.workspace.diff_status` RPC result.
public struct MobileWorkspaceDiffStatusResponse: Decodable, Sendable {
    /// Repository root on the paired Mac.
    public let repoRoot: String
    /// Changed files in display order.
    public let files: [MobileWorkspaceDiffStatusFile]
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
        repoRoot = try container.decode(String.self, forKey: .repoRoot)
        files = try container.decode([MobileWorkspaceDiffStatusFile].self, forKey: .files)
        truncated = try container.decodeIfPresent(Bool.self, forKey: .truncated) ?? false
    }

    /// Creates a diff-status response from raw JSON data.
    /// - Parameter data: The RPC result payload.
    public init(data: Data) throws {
        self = try JSONDecoder().decode(Self.self, from: data)
    }
}
