import Foundation

/// Metadata for a Mac-hosted artifact path referenced by a chat session.
public struct ChatArtifactStat: Sendable, Equatable, Codable {
    /// Whether the artifact existed when the Mac handled the request.
    public let exists: Bool
    /// Whether the path is a directory.
    public let isDirectory: Bool
    /// Raw byte size for files, or the filesystem-reported size for directories.
    public let size: Int64
    /// Last modification time as reported by the Mac filesystem.
    public let modifiedAt: Date
    /// The artifact preview category.
    public let kind: ChatArtifactKind
    /// Best-effort MIME type inferred by the Mac, when known.
    public let mimeType: String?
    /// Intrinsic image width in pixels, when the artifact is an image and the
    /// Mac can read dimensions without fetching thumbnail bytes.
    public let pixelWidth: Int?
    /// Intrinsic image height in pixels, when the artifact is an image and the
    /// Mac can read dimensions without fetching thumbnail bytes.
    public let pixelHeight: Int?

    /// Creates artifact metadata.
    ///
    /// - Parameters:
    ///   - exists: Whether the artifact existed when statted.
    ///   - isDirectory: Whether the path is a directory.
    ///   - size: Raw byte size or filesystem-reported directory size.
    ///   - modifiedAt: Last modification time.
    ///   - kind: Preview category.
    ///   - mimeType: Best-effort MIME type.
    ///   - pixelWidth: Intrinsic image width in pixels.
    ///   - pixelHeight: Intrinsic image height in pixels.
    public init(
        exists: Bool,
        isDirectory: Bool,
        size: Int64,
        modifiedAt: Date,
        kind: ChatArtifactKind,
        mimeType: String? = nil,
        pixelWidth: Int? = nil,
        pixelHeight: Int? = nil
    ) {
        self.exists = exists
        self.isDirectory = isDirectory
        self.size = size
        self.modifiedAt = modifiedAt
        self.kind = kind
        self.mimeType = mimeType
        self.pixelWidth = Self.validPixelDimension(pixelWidth)
        self.pixelHeight = Self.validPixelDimension(pixelHeight)
    }

    private enum CodingKeys: String, CodingKey {
        case exists
        case isDirectory = "is_directory"
        case size
        case modifiedAt = "modified_at"
        case kind
        case mimeType = "mime_type"
        case pixelWidth = "pixel_width"
        case pixelHeight = "pixel_height"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        exists = try container.decode(Bool.self, forKey: .exists)
        isDirectory = try container.decode(Bool.self, forKey: .isDirectory)
        size = try container.decode(Int64.self, forKey: .size)
        if let seconds = try? container.decode(Double.self, forKey: .modifiedAt) {
            modifiedAt = Date(timeIntervalSince1970: seconds)
        } else {
            modifiedAt = try container.decode(Date.self, forKey: .modifiedAt)
        }
        kind = try container.decode(ChatArtifactKind.self, forKey: .kind)
        mimeType = try container.decodeIfPresent(String.self, forKey: .mimeType)
        pixelWidth = Self.validPixelDimension(try container.decodeIfPresent(Int.self, forKey: .pixelWidth))
        pixelHeight = Self.validPixelDimension(try container.decodeIfPresent(Int.self, forKey: .pixelHeight))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(exists, forKey: .exists)
        try container.encode(isDirectory, forKey: .isDirectory)
        try container.encode(size, forKey: .size)
        try container.encode(modifiedAt.timeIntervalSince1970, forKey: .modifiedAt)
        try container.encode(kind, forKey: .kind)
        try container.encodeIfPresent(mimeType, forKey: .mimeType)
        try container.encodeIfPresent(pixelWidth, forKey: .pixelWidth)
        try container.encodeIfPresent(pixelHeight, forKey: .pixelHeight)
    }

    private static func validPixelDimension(_ value: Int?) -> Int? {
        guard let value, value > 0 else { return nil }
        return value
    }
}
