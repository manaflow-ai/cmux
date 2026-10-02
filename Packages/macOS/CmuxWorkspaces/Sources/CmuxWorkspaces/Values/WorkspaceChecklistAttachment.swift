public import Foundation

/// An image file attached to a workspace checklist item.
///
/// The attachment stores only file identity and lightweight metadata. Image
/// bytes remain user-owned at ``filePath`` and are never copied or deleted by
/// checklist value operations.
public struct WorkspaceChecklistAttachment: Codable, Sendable, Identifiable, Hashable {
    /// Stable identity for this attachment reference.
    public var id: UUID
    /// Name to show in compact UI.
    public var displayName: String
    /// Persisted path to the user-owned image file.
    public var filePath: String
    /// Optional file size captured when the attachment was created.
    public var byteCount: Int64?
    /// Optional UTType or MIME-like identifier captured for display/filtering.
    public var contentTypeIdentifier: String?
    /// Optional pixel width captured from metadata.
    public var pixelWidth: Int?
    /// Optional pixel height captured from metadata.
    public var pixelHeight: Int?

    /// The persisted path as a file URL.
    public var fileURL: URL {
        URL(fileURLWithPath: filePath)
    }

    /// Creates an attachment reference from a file path and optional metadata.
    public init(
        id: UUID = UUID(),
        displayName: String,
        filePath: String,
        byteCount: Int64? = nil,
        contentTypeIdentifier: String? = nil,
        pixelWidth: Int? = nil,
        pixelHeight: Int? = nil
    ) {
        self.id = id
        self.filePath = filePath
        self.displayName = Self.normalizedDisplayName(displayName, filePath: filePath)
        self.byteCount = Self.positive(byteCount)
        self.contentTypeIdentifier = Self.normalizedOptionalString(contentTypeIdentifier)
        self.pixelWidth = Self.positive(pixelWidth)
        self.pixelHeight = Self.positive(pixelHeight)
    }

    /// Creates an attachment reference from a file URL and optional metadata.
    public init(
        id: UUID = UUID(),
        displayName: String,
        fileURL: URL,
        byteCount: Int64? = nil,
        contentTypeIdentifier: String? = nil,
        pixelWidth: Int? = nil,
        pixelHeight: Int? = nil
    ) {
        self.init(
            id: id,
            displayName: displayName,
            filePath: fileURL.path,
            byteCount: byteCount,
            contentTypeIdentifier: contentTypeIdentifier,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight
        )
    }

    /// Checks whether the referenced file exists without decoding image bytes.
    public func fileExists(fileManager: FileManager = .default) -> Bool {
        fileManager.fileExists(atPath: filePath)
    }

    /// Checks whether the referenced file is currently missing.
    public func isMissing(fileManager: FileManager = .default) -> Bool {
        !fileExists(fileManager: fileManager)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case displayName
        case filePath
        case fileURL
        case byteCount
        case contentTypeIdentifier
        case pixelWidth
        case pixelHeight
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedPath = try Self.decodePath(from: container)
        guard let filePath = decodedPath, !filePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .filePath,
                in: container,
                debugDescription: "Checklist attachment is missing a file path"
            )
        }
        let displayName = (try? container.decode(String.self, forKey: .displayName)) ?? ""
        self.init(
            id: (try? container.decode(UUID.self, forKey: .id)) ?? UUID(),
            displayName: displayName,
            filePath: filePath,
            byteCount: try? container.decode(Int64.self, forKey: .byteCount),
            contentTypeIdentifier: try? container.decode(String.self, forKey: .contentTypeIdentifier),
            pixelWidth: try? container.decode(Int.self, forKey: .pixelWidth),
            pixelHeight: try? container.decode(Int.self, forKey: .pixelHeight)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(filePath, forKey: .filePath)
        try container.encodeIfPresent(byteCount, forKey: .byteCount)
        try container.encodeIfPresent(contentTypeIdentifier, forKey: .contentTypeIdentifier)
        try container.encodeIfPresent(pixelWidth, forKey: .pixelWidth)
        try container.encodeIfPresent(pixelHeight, forKey: .pixelHeight)
    }

    private static func decodePath(
        from container: KeyedDecodingContainer<CodingKeys>
    ) throws -> String? {
        if let filePath = try? container.decode(String.self, forKey: .filePath) {
            return filePath
        }
        if let fileURL = try? container.decode(URL.self, forKey: .fileURL) {
            return fileURL.path
        }
        if let fileURLString = try? container.decode(String.self, forKey: .fileURL) {
            if let url = URL(string: fileURLString), url.isFileURL {
                return url.path
            }
            return fileURLString
        }
        return nil
    }

    private static func normalizedDisplayName(_ displayName: String, filePath: String) -> String {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return trimmed
        }
        let fallback = URL(fileURLWithPath: filePath).lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        return fallback.isEmpty ? "attachment" : fallback
    }

    private static func normalizedOptionalString(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func positive<T: FixedWidthInteger>(_ value: T?) -> T? {
        guard let value, value > 0 else { return nil }
        return value
    }
}
