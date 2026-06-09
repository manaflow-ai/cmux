public import Foundation

/// Typed decoder for the `mobile.workspace.picture.get` RPC result.
///
/// The Mac returns the workspace id, the hash that was requested, and the avatar
/// PNG as base64 (or null when the workspace has no picture or the hash no longer
/// matches). The phone caches the decoded bytes by hash so an unchanged avatar is
/// never refetched.
public struct MobileWorkspacePictureResponse: Decodable, Sendable {
    /// The workspace the picture belongs to.
    public let workspaceID: String
    /// The hash that was requested (echoed back).
    public let hash: String
    /// The avatar PNG as base64, or `nil` when there is no matching picture.
    public let imageBase64: String?

    private enum CodingKeys: String, CodingKey {
        case workspaceID = "workspace_id"
        case hash
        case imageBase64 = "image_base64"
    }

    /// Decode a picture response from raw JSON data.
    /// - Parameter data: The RPC result payload.
    /// - Returns: The decoded response.
    /// - Throws: A decoding error if the payload is malformed.
    public static func decode(_ data: Data) throws -> MobileWorkspacePictureResponse {
        try JSONDecoder().decode(Self.self, from: data)
    }

    /// The decoded avatar bytes, or `nil` when absent/invalid.
    public var imageData: Data? {
        guard let imageBase64, !imageBase64.isEmpty else { return nil }
        return Data(base64Encoded: imageBase64)
    }
}
