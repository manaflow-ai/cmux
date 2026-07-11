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

    /// Decodes a one-file diff response. File identity and diff text are
    /// required so malformed payloads cannot be shown under the selected path.
    /// - Parameter decoder: The decoder for the RPC result payload.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        path = try container.decode(String.self, forKey: .path)
        guard !path.isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .path,
                in: container,
                debugDescription: "Diff file path must not be empty"
            )
        }
        unifiedDiff = try container.decode(String.self, forKey: .unifiedDiff)
        truncated = try container.decodeIfPresent(Bool.self, forKey: .truncated) ?? false
    }

    /// Decode a one-file diff response from raw JSON data.
    /// - Parameter data: The RPC result payload.
    /// - Returns: The decoded response.
    public static func decode(_ data: Data) throws -> MobileWorkspaceDiffFileResponse {
        try JSONDecoder().decode(Self.self, from: data)
    }
}
