import Foundation

/// Carries the text and attachment flags for a user-authored transcript entry.
public struct UserMessagePayload: Codable, Hashable, Sendable {
    /// The user-authored text.
    public let text: String
    /// The number of attachments associated with the message.
    public let attachmentCount: Int
    /// Whether any attachment is an image.
    public let hasImage: Bool

    private enum CodingKeys: String, CodingKey {
        case text
        case attachmentCount = "attachment_count"
        case hasImage = "has_image"
    }

    /// Creates a user message payload.
    /// - Parameters:
    ///   - text: The user-authored text.
    ///   - attachmentCount: The number of attachments associated with the message.
    ///   - hasImage: Whether any attachment is an image.
    public init(text: String, attachmentCount: Int, hasImage: Bool) {
        self.text = text
        self.attachmentCount = attachmentCount
        self.hasImage = hasImage
    }
}
