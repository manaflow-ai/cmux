import Foundation

/// A derived image of an attachment: a video's poster or an image's preview
/// (JPEG or WebP), stored by its own SHA-256 next to the attachment.
public struct ConversationDerivedImage: Codable, Sendable, Hashable {
    public var hash: String
    public var mimeType: String
    public var byteCount: Int

    public init(hash: String, mimeType: String, byteCount: Int) {
        self.hash = hash
        self.mimeType = mimeType
        self.byteCount = byteCount
    }

    enum CodingKeys: String, CodingKey {
        case hash
        case mimeType = "mime_type"
        case byteCount = "byte_count"
    }
}

/// An `attachment` part (`local-attachments-v1`, cmux-tui spec/commands.md):
/// a file the conversation holds by SHA-256. The owner commits it only when
/// the author uploaded the hash here (or a message already references it)
/// with the same type, size and derived image.
public struct ConversationAttachment: Codable, Sendable, Hashable {
    public var hash: String
    public var name: String
    public var mimeType: String
    public var byteCount: Int
    public var width: Int?
    public var height: Int?
    public var durationMs: Int?
    /// Video only.
    public var poster: ConversationDerivedImage?
    /// Image only.
    public var preview: ConversationDerivedImage?

    public init(hash: String, name: String, mimeType: String, byteCount: Int, width: Int? = nil, height: Int? = nil,
                durationMs: Int? = nil, poster: ConversationDerivedImage? = nil, preview: ConversationDerivedImage? = nil) {
        self.hash = hash
        self.name = name
        self.mimeType = mimeType
        self.byteCount = byteCount
        self.width = width
        self.height = height
        self.durationMs = durationMs
        self.poster = poster
        self.preview = preview
    }

    enum CodingKeys: String, CodingKey {
        case hash, name, width, height, poster, preview
        case mimeType = "mime_type"
        case byteCount = "byte_count"
        case durationMs = "duration_ms"
    }
}

/// The owner's record of an uploaded hash: what a part must match.
public struct StoredConversationAttachment: Decodable, Sendable, Hashable {
    public var hash: String
    public var mimeType: String
    public var byteCount: Int
    public var poster: ConversationDerivedImage?
    public var preview: ConversationDerivedImage?

    enum CodingKeys: String, CodingKey {
        case hash, poster, preview
        case mimeType = "mime_type"
        case byteCount = "byte_count"
    }
}

/// A `link_preview` part (cmux-tui spec/commands.md): a link with the
/// preview its sender fetched; receivers render only from it. `image` is an
/// ordinary image attachment (JPEG or WebP, at most 512 KB) the sender
/// uploaded to the conversation, read back by its hash.
public struct ConversationLinkPreview: Codable, Sendable, Hashable {
    public var url: String
    public var title: String?
    public var site: String?
    public var image: ConversationDerivedImage?

    public init(url: String, title: String? = nil, site: String? = nil, image: ConversationDerivedImage? = nil) {
        self.url = url
        self.title = title
        self.site = site
        self.image = image
    }
}
