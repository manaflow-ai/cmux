import Foundation

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

    fileprivate enum AliasCodingKeys: String, CodingKey {
        case media
        case kind
        case displayName
        case fileName
        case file_name
        case name
        case hostPath
        case path
        case file_path
        case mimeType
        case mediaType
        case media_type
        case byteCount
        case size
        case pixelWidth
        case width
        case pixelHeight
        case height
    }

    /// Decodes both current attachment metadata and older payloads that only
    /// carried media, display name, and host path. Datasource aliases are
    /// intentionally normalized here so renderers can reserve image preview
    /// geometry before thumbnail bytes arrive.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let aliases = try decoder.container(keyedBy: AliasCodingKeys.self)

        let decodedDisplayName = try container.decodeIfPresent(String.self, forKey: .displayName)
            ?? aliases.decodeString(forKey: .displayName)
            ?? aliases.decodeString(forKey: .fileName)
            ?? aliases.decodeString(forKey: .file_name)
            ?? aliases.decodeString(forKey: .name)
        let decodedHostPath = try container.decodeIfPresent(String.self, forKey: .hostPath)
            ?? aliases.decodeString(forKey: .hostPath)
            ?? aliases.decodeString(forKey: .path)
            ?? aliases.decodeString(forKey: .file_path)
        let decodedMimeType = try container.decodeIfPresent(String.self, forKey: .mimeType)
            ?? aliases.decodeString(forKey: .mimeType)
            ?? aliases.decodeString(forKey: .mediaType)
            ?? aliases.decodeString(forKey: .media_type)

        media = (try? container.decode(Media.self, forKey: .media))
            ?? aliases.decodeMedia(forKey: .media)
            ?? aliases.decodeMedia(forKey: .kind)
            ?? Self.inferredMedia(
                mimeType: decodedMimeType,
                displayName: decodedDisplayName,
                hostPath: decodedHostPath
            )
            ?? .file
        displayName = decodedDisplayName
        hostPath = decodedHostPath
        mimeType = decodedMimeType
        byteCount = try container.decodeIfPresent(Int.self, forKey: .byteCount)
            ?? aliases.decodeInt(forKey: .byteCount)
            ?? aliases.decodeInt(forKey: .size)
        pixelWidth = try container.decodeIfPresent(Int.self, forKey: .pixelWidth)
            ?? aliases.decodeInt(forKey: .pixelWidth)
            ?? aliases.decodeInt(forKey: .width)
        pixelHeight = try container.decodeIfPresent(Int.self, forKey: .pixelHeight)
            ?? aliases.decodeInt(forKey: .pixelHeight)
            ?? aliases.decodeInt(forKey: .height)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(media, forKey: .media)
        try container.encodeIfPresent(displayName, forKey: .displayName)
        try container.encodeIfPresent(hostPath, forKey: .hostPath)
        try container.encodeIfPresent(mimeType, forKey: .mimeType)
        try container.encodeIfPresent(byteCount, forKey: .byteCount)
        try container.encodeIfPresent(pixelWidth, forKey: .pixelWidth)
        try container.encodeIfPresent(pixelHeight, forKey: .pixelHeight)
    }

    private static func inferredMedia(
        mimeType: String?,
        displayName: String?,
        hostPath: String?
    ) -> Media? {
        if let media = Media.normalized(from: mimeType) {
            return media
        }
        let candidatePath = displayName ?? hostPath
        guard let candidatePath else { return nil }
        let lowercasedExtension = URL(fileURLWithPath: candidatePath).pathExtension.lowercased()
        switch lowercasedExtension {
        case "apng", "avif", "bmp", "gif", "heic", "heif", "jpeg", "jpg", "png", "tif", "tiff", "webp":
            return .image
        default:
            return nil
        }
    }
}

private extension ChatAttachment.Media {
    static func normalized(from rawValue: String?) -> Self? {
        guard let rawValue else { return nil }
        let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let media = Self(rawValue: normalized) {
            return media
        }
        if normalized.hasPrefix("image/") {
            return .image
        }
        if normalized.hasPrefix("application/") || normalized.hasPrefix("text/") || normalized.hasPrefix("video/") {
            return .file
        }
        return nil
    }
}

private extension KeyedDecodingContainer where Key == ChatAttachment.AliasCodingKeys {
    func decodeString(forKey key: Key) -> String? {
        try? decodeIfPresent(String.self, forKey: key)
    }

    func decodeInt(forKey key: Key) -> Int? {
        if let int = try? decodeIfPresent(Int.self, forKey: key) {
            return int
        }
        if let int64 = try? decodeIfPresent(Int64.self, forKey: key),
           int64 >= Int64(Int.min),
           int64 <= Int64(Int.max) {
            return Int(int64)
        }
        return nil
    }

    func decodeMedia(forKey key: Key) -> ChatAttachment.Media? {
        ChatAttachment.Media.normalized(from: decodeString(forKey: key))
    }
}
