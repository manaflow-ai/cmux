/// One file attached to a message.
public struct ConversationAttachment: Hashable, Sendable, Identifiable {
    /// Client-generated identifier of the upload; stable across retries.
    public let uploadID: String
    /// The file's display name.
    public var name: String
    /// The file's media type, such as `image/png` or `application/pdf`.
    public var mimeType: String
    /// The file's size in bytes.
    public var size: UInt64
    /// Lowercase hex SHA-256 of the file's bytes.
    public var sha256: String
    /// Upload identifier of a small preview of the file, when one was sent.
    public var thumbnailUploadID: String?
    /// Where the upload stands.
    public var state: AttachmentState

    /// The upload identifier, as ``Identifiable/id``.
    public var id: String { uploadID }

    /// Creates an attachment description.
    /// - Parameters:
    ///   - uploadID: Client-generated identifier of the upload.
    ///   - name: Display name.
    ///   - mimeType: Media type.
    ///   - size: Size in bytes.
    ///   - sha256: Lowercase hex SHA-256 of the bytes.
    ///   - thumbnailUploadID: Upload identifier of a preview, if any.
    ///   - state: Where the upload stands; defaults to nothing received yet.
    public init(uploadID: String, name: String, mimeType: String, size: UInt64, sha256: String, thumbnailUploadID: String? = nil, state: AttachmentState = .uploading(received: 0)) {
        self.uploadID = uploadID
        self.name = name
        self.mimeType = mimeType
        self.size = size
        self.sha256 = sha256
        self.thumbnailUploadID = thumbnailUploadID
        self.state = state
    }

    /// Whether the file is an image, by its media type.
    public var isImage: Bool { mimeType.hasPrefix("image/") }
}
