public import Foundation

/// A file on this device that a message carries to the backend.
///
/// The bytes are read from ``fileURL`` when uploading; nothing is copied or
/// re-encoded. ``thumbnail`` is an optional small preview, uploaded first so
/// other clients can show the file before the original arrives.
public struct OutgoingAttachment: Hashable, Sendable, Codable {
    /// A small preview file uploaded ahead of the original.
    public struct Thumbnail: Hashable, Sendable, Codable {
        /// Client-generated identifier of the preview's upload.
        public var uploadID: String
        /// Where the preview's bytes are on this device.
        public var fileURL: URL
        /// The preview's media type.
        public var mimeType: String
        /// The preview's size in bytes.
        public var size: UInt64
        /// Lowercase hex SHA-256 of the preview.
        public var sha256: String

        /// Creates a preview description.
        /// - Parameters:
        ///   - uploadID: Upload identifier.
        ///   - fileURL: Local file.
        ///   - mimeType: Media type.
        ///   - size: Size in bytes.
        ///   - sha256: Hex SHA-256.
        public init(uploadID: String, fileURL: URL, mimeType: String, size: UInt64, sha256: String) {
            self.uploadID = uploadID
            self.fileURL = fileURL
            self.mimeType = mimeType
            self.size = size
            self.sha256 = sha256
        }
    }

    /// Client-generated identifier of the upload, stable across retries.
    public var uploadID: String
    /// Where the bytes are on this device.
    public var fileURL: URL
    /// The display name.
    public var name: String
    /// The media type.
    public var mimeType: String
    /// The size in bytes.
    public var size: UInt64
    /// Lowercase hex SHA-256 of the bytes.
    public var sha256: String
    /// A preview uploaded ahead of the original, if any.
    public var thumbnail: Thumbnail?

    /// Creates an outgoing file.
    /// - Parameters:
    ///   - uploadID: Upload identifier.
    ///   - fileURL: Local file.
    ///   - name: Display name.
    ///   - mimeType: Media type.
    ///   - size: Size in bytes.
    ///   - sha256: Hex SHA-256.
    ///   - thumbnail: Preview, if any.
    public init(uploadID: String, fileURL: URL, name: String, mimeType: String, size: UInt64, sha256: String, thumbnail: Thumbnail? = nil) {
        self.uploadID = uploadID
        self.fileURL = fileURL
        self.name = name
        self.mimeType = mimeType
        self.size = size
        self.sha256 = sha256
        self.thumbnail = thumbnail
    }

    /// How the conversation shows it before the backend reports on it.
    public var asConversationAttachment: ConversationAttachment {
        ConversationAttachment(uploadID: uploadID, name: name, mimeType: mimeType, size: size, sha256: sha256, thumbnailUploadID: thumbnail?.uploadID)
    }
}
