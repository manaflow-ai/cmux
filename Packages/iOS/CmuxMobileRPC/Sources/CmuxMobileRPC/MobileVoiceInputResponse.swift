public import Foundation

/// Response returned after Voice Mode inserts text into the focused Mac terminal.
public struct MobileVoiceInputResponse: Codable, Equatable, Sendable {
    /// Workspace that received the text.
    public let workspaceID: String
    /// Surface that received the text.
    public let surfaceID: String
    /// Surface title at insertion time.
    public let surfaceTitle: String?
    /// Whether the terminal queued the input instead of sending immediately.
    public let queued: Bool

    private enum CodingKeys: String, CodingKey {
        case workspaceID = "workspace_id"
        case surfaceID = "surface_id"
        case surfaceTitle = "surface_title"
        case queued
    }

    /// Decode a voice-input response from raw JSON.
    /// - Parameter data: JSON object data.
    /// - Returns: The decoded response.
    public static func decode(_ data: Data) throws -> MobileVoiceInputResponse {
        try JSONDecoder().decode(Self.self, from: data)
    }
}
