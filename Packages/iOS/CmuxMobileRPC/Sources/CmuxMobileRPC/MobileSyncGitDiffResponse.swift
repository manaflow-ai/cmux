public import Foundation

/// Typed decoder for the size-bounded workspace Git diff RPC result.
public struct MobileSyncGitDiffResponse: Decodable, Sendable {
    /// The baseline identifier, currently `worktree`.
    public let baseline: String
    /// Concatenated unified patch text for included paths.
    public let patch: String
    /// Requested paths represented in `patch`.
    public let included: [String]
    /// Requested paths omitted after the response cap was reached.
    public let truncated: [String]
    /// Requested paths whose individual patch alone exceeded the response cap.
    public let tooLarge: [MobileSyncGitDiffTooLargeFile]

    private enum CodingKeys: String, CodingKey {
        case baseline
        case patch
        case included
        case truncated
        case tooLarge = "too_large"
    }

    /// Decodes a workspace Git diff response from raw JSON data.
    /// - Parameter data: The RPC result payload.
    /// - Returns: The decoded response.
    /// - Throws: A decoding error if the payload is malformed.
    public static func decode(_ data: Data) throws -> MobileSyncGitDiffResponse {
        try JSONDecoder().decode(Self.self, from: data)
    }
}
