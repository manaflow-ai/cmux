/// An image or file the user attached to a prompt.
///
/// The binary payload travels out-of-band (image paste RPC); the transcript
/// message carries only display metadata.
public struct ChatAttachment: Sendable, Equatable, Codable {
    /// The attachment's media category.
    public enum Media: String, Sendable, Equatable, Codable {
        /// A raster image (photo, screenshot).
        case image
        /// Any other file.
        case file
    }

    /// The attachment's media category.
    public let media: Media

    /// Display name, when one is known (e.g. the original filename).
    public let displayName: String?

    /// Path on the host where the attachment was materialized, when known.
    /// Lets renderers reference what the agent sees.
    public let hostPath: String?

    /// MIME media type reported by the transcript source, when known.
    public let mimeType: String?

    /// Attachment size in bytes, when known.
    public let byteCount: Int?

    /// Original image width in pixels, when known.
    public let pixelWidth: Int?

    /// Original image height in pixels, when known.
    public let pixelHeight: Int?

    /// Creates attachment metadata.
    ///
    /// - Parameters:
    ///   - media: The media category.
    ///   - displayName: Display name when known.
    ///   - hostPath: Host-side materialized path when known.
    ///   - mimeType: MIME media type when known.
    ///   - byteCount: Attachment size in bytes when known.
    ///   - pixelWidth: Original image width in pixels when known.
    ///   - pixelHeight: Original image height in pixels when known.
    public init(
        media: Media,
        displayName: String? = nil,
        hostPath: String? = nil,
        mimeType: String? = nil,
        byteCount: Int? = nil,
        pixelWidth: Int? = nil,
        pixelHeight: Int? = nil
    ) {
        self.media = media
        self.displayName = displayName
        self.hostPath = hostPath
        self.mimeType = mimeType
        self.byteCount = byteCount
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }

    private enum CodingKeys: String, CodingKey {
        case media
        case displayName = "display_name"
        case hostPath = "host_path"
        case mimeType = "mime_type"
        case byteCount = "byte_count"
        case pixelWidth = "pixel_width"
        case pixelHeight = "pixel_height"
    }

    /// Decodes both current attachment metadata and older payloads that only
    /// carried media, display name, and host path.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        media = try container.decode(Media.self, forKey: .media)
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
        hostPath = try container.decodeIfPresent(String.self, forKey: .hostPath)
        mimeType = try container.decodeIfPresent(String.self, forKey: .mimeType)
        byteCount = try container.decodeIfPresent(Int.self, forKey: .byteCount)
        pixelWidth = try container.decodeIfPresent(Int.self, forKey: .pixelWidth)
        pixelHeight = try container.decodeIfPresent(Int.self, forKey: .pixelHeight)
    }
}
