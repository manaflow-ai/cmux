import Foundation

/// A reference to an image attachment in a transcript, stored by id rather than
/// inline.
///
/// Transcripts can embed large base64 image payloads. The model deliberately
/// keeps only a lightweight reference (id, media type, byte count) so a
/// ``Conversation`` stays cheap to hold and diff; the bytes are fetched lazily
/// by a later loader when an image actually needs to render.
public struct ImageRef: Codable, Hashable, Sendable, Identifiable {
    /// A stable identifier for the image within its conversation.
    public let id: String

    /// The image's MIME media type (e.g. `image/png`), or `nil` if unknown.
    public let mediaType: String?

    /// The size of the referenced image in bytes, or `nil` if unknown.
    public let byteCount: Int?

    /// Creates an image reference.
    ///
    /// - Parameters:
    ///   - id: A stable identifier for the image within its conversation.
    ///   - mediaType: The image's MIME media type, if known.
    ///   - byteCount: The image's size in bytes, if known.
    public init(id: String, mediaType: String? = nil, byteCount: Int? = nil) {
        self.id = id
        self.mediaType = mediaType
        self.byteCount = byteCount
    }
}
