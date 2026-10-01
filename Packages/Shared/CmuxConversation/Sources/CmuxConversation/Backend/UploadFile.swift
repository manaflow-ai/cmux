public import Foundation

/// One file to upload: an attachment's original or its preview.
public struct UploadFile: Hashable, Sendable {
    /// Client-generated upload identifier.
    public var uploadID: String
    /// Where the bytes are on this device.
    public var fileURL: URL
    /// Display name.
    public var name: String
    /// Media type.
    public var mimeType: String
    /// Size in bytes.
    public var size: UInt64
    /// Lowercase hex SHA-256.
    public var sha256: String

    /// Creates an upload description.
    /// - Parameters:
    ///   - uploadID: Upload identifier.
    ///   - fileURL: Local file.
    ///   - name: Display name.
    ///   - mimeType: Media type.
    ///   - size: Size in bytes.
    ///   - sha256: Hex SHA-256.
    public init(uploadID: String, fileURL: URL, name: String, mimeType: String, size: UInt64, sha256: String) {
        self.uploadID = uploadID
        self.fileURL = fileURL
        self.name = name
        self.mimeType = mimeType
        self.size = size
        self.sha256 = sha256
    }

    /// The upload for an attachment's original bytes.
    /// - Parameter attachment: The outgoing attachment.
    public init(original attachment: OutgoingAttachment) {
        self.init(uploadID: attachment.uploadID, fileURL: attachment.fileURL, name: attachment.name, mimeType: attachment.mimeType, size: attachment.size, sha256: attachment.sha256)
    }

    /// The upload for an attachment's preview.
    /// - Parameter thumbnail: The preview.
    public init(thumbnail: OutgoingAttachment.Thumbnail) {
        self.init(uploadID: thumbnail.uploadID, fileURL: thumbnail.fileURL, name: "thumbnail", mimeType: thumbnail.mimeType, size: thumbnail.size, sha256: thumbnail.sha256)
    }
}
