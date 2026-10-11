import Foundation

/// Which bytes of an attachment a read returns.
public enum ConversationAttachmentVariant: String, Codable, Sendable, Hashable {
    case original, poster, preview
}
