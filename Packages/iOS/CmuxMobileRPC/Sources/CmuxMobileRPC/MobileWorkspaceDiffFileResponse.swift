public import Foundation

/// Typed decoder for the `mobile.workspace.diff_file` RPC result.
public struct MobileWorkspaceDiffFileResponse: Decodable, Sendable, Equatable {
    /// Repository-relative path returned by the Mac.
    public let path: String
    /// Raw unified diff text.
    public let unifiedDiff: String
    /// Whether the Mac capped the diff text.
    public let truncated: Bool

    private enum CodingKeys: String, CodingKey {
        case path
        case unifiedDiff = "unified_diff"
        case truncated
    }

    /// Decodes a one-file diff response, tolerating absent optional fields from
    /// older or future Mac builds.
    /// - Parameter decoder: The decoder for the RPC result payload.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        path = try container.decodeIfPresent(String.self, forKey: .path) ?? ""
        unifiedDiff = try container.decodeIfPresent(String.self, forKey: .unifiedDiff) ?? ""
        truncated = try container.decodeIfPresent(Bool.self, forKey: .truncated) ?? false
    }

    /// Decode a one-file diff response from raw JSON data.
    /// - Parameter data: The RPC result payload.
    /// - Returns: The decoded response.
    public static func decode(_ data: Data) throws -> MobileWorkspaceDiffFileResponse {
        try JSONDecoder().decode(Self.self, from: data)
    }
}
