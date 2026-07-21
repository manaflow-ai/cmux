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
        height: Int? = nil
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
    }
}
