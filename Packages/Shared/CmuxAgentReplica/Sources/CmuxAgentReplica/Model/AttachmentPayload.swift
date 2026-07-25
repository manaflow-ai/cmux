import Foundation

/// Carries an attachment transcript entry.
public struct AttachmentPayload: Codable, Hashable, Sendable {
    /// The attachment kind identifier.
    public let kind: String
    /// A compact attachment summary.
    public let summary: String
    /// Stable attachment identifier, when reported.
    public let attachmentID: String?
    /// User-facing filename or label.
    public let displayName: String?
    /// Materialized host path, when reported.
    public let hostPath: String?
    /// MIME media type, when reported.
    public let mimeType: String?
    /// Payload size in bytes, when reported.
    public let byteCount: Int?
    /// Pixel width for image attachments.
    public let width: Int?
    /// Pixel height for image attachments.
    public let height: Int?
    /// Author role for generated attachment rows, when the transcript source
    /// can distinguish user attachments from agent-produced previews.
    public let authorRole: String?

    private enum CodingKeys: String, CodingKey {
        case kind = "attachment_kind"
        case summary
        case attachmentID = "attachment_id"
        case displayName = "display_name"
        case hostPath = "host_path"
        case mimeType = "mime_type"
        case byteCount = "byte_count"
        case width
        case height
        case authorRole = "author_role"
    }

    private enum AliasCodingKeys: String, CodingKey {
        case kind
        case type
        case id
        case fileName
        case file_name
        case name
        case path
        case file_path
        case mediaType
        case media_type
        case byteCount
        case size
        case pixelWidth
        case pixel_width
        case pixelHeight
        case pixel_height
        case authorRole
        case role
    }

    /// Creates an attachment payload.
    /// - Parameters:
    ///   - kind: The attachment kind identifier.
    ///   - summary: A compact attachment summary.
    public init(
        kind: String,
        summary: String,
        attachmentID: String? = nil,
        displayName: String? = nil,
        hostPath: String? = nil,
        mimeType: String? = nil,
        byteCount: Int? = nil,
        width: Int? = nil,
        height: Int? = nil,
        authorRole: String? = nil
    ) {
        self.kind = kind
        self.summary = summary
        self.attachmentID = attachmentID
        self.displayName = displayName
        self.hostPath = hostPath
        self.mimeType = mimeType
        self.byteCount = byteCount
        self.width = width
        self.height = height
        self.authorRole = authorRole
    }

    /// Decodes canonical payloads plus datasource aliases used by transcript
    /// sources and artifact metadata APIs. Keeping this tolerant at the replica
    /// boundary lets iOS reserve the correct preview geometry before loading
    /// thumbnail bytes.
    public init(from decoder: any Decoder) throws {
        let canonical = try decoder.container(keyedBy: CodingKeys.self)
        let aliases = try decoder.container(keyedBy: AliasCodingKeys.self)

        let decodedDisplayName = try canonical.decodeIfPresent(String.self, forKey: .displayName)
            ?? aliases.decodeIfPresent(String.self, forKey: .fileName)
            ?? aliases.decodeIfPresent(String.self, forKey: .file_name)
            ?? aliases.decodeIfPresent(String.self, forKey: .name)
        let decodedHostPath = try canonical.decodeIfPresent(String.self, forKey: .hostPath)
            ?? aliases.decodeIfPresent(String.self, forKey: .path)
            ?? aliases.decodeIfPresent(String.self, forKey: .file_path)
        let decodedKind = try canonical.decodeIfPresent(String.self, forKey: .kind)
            ?? aliases.decodeIfPresent(String.self, forKey: .type)
            ?? aliases.decodeIfPresent(String.self, forKey: .kind)
            ?? "file"
        let decodedSummary = try canonical.decodeIfPresent(String.self, forKey: .summary)
            ?? decodedDisplayName
            ?? decodedHostPath
            ?? "\(decodedKind.capitalized) attachment"

        kind = decodedKind
        summary = decodedSummary
        attachmentID = try canonical.decodeIfPresent(String.self, forKey: .attachmentID)
            ?? aliases.decodeIfPresent(String.self, forKey: .id)
        displayName = decodedDisplayName
        hostPath = decodedHostPath
        mimeType = try canonical.decodeIfPresent(String.self, forKey: .mimeType)
            ?? aliases.decodeIfPresent(String.self, forKey: .mediaType)
            ?? aliases.decodeIfPresent(String.self, forKey: .media_type)
        byteCount = try canonical.decodeIfPresent(Int.self, forKey: .byteCount)
            ?? aliases.decodeIfPresent(Int.self, forKey: .byteCount)
            ?? aliases.decodeIfPresent(Int.self, forKey: .size)
        width = try canonical.decodeIfPresent(Int.self, forKey: .width)
            ?? aliases.decodeIfPresent(Int.self, forKey: .pixelWidth)
            ?? aliases.decodeIfPresent(Int.self, forKey: .pixel_width)
        height = try canonical.decodeIfPresent(Int.self, forKey: .height)
            ?? aliases.decodeIfPresent(Int.self, forKey: .pixelHeight)
            ?? aliases.decodeIfPresent(Int.self, forKey: .pixel_height)
        authorRole = try canonical.decodeIfPresent(String.self, forKey: .authorRole)
            ?? aliases.decodeIfPresent(String.self, forKey: .authorRole)
            ?? aliases.decodeIfPresent(String.self, forKey: .role)
    }

    /// Encodes the canonical replica payload. Aliases are read-only migration
    /// support so the wire format stays deterministic.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encode(summary, forKey: .summary)
        try container.encodeIfPresent(attachmentID, forKey: .attachmentID)
        try container.encodeIfPresent(displayName, forKey: .displayName)
        try container.encodeIfPresent(hostPath, forKey: .hostPath)
        try container.encodeIfPresent(mimeType, forKey: .mimeType)
        try container.encodeIfPresent(byteCount, forKey: .byteCount)
        try container.encodeIfPresent(width, forKey: .width)
        try container.encodeIfPresent(height, forKey: .height)
        try container.encodeIfPresent(authorRole, forKey: .authorRole)
    }
}
