#if os(iOS)
import Foundation

/// A prepared JPEG photo attachment ready for feedback upload.
public struct MobileFeedbackPhotoAttachment: Identifiable, Sendable {
    /// Stable identity for SwiftUI lists.
    public let id: UUID
    /// Filename sent in the multipart upload.
    public let fileName: String
    /// MIME type sent in the multipart upload.
    public let mimeType: String
    /// Encoded attachment bytes.
    public let data: Data

    /// Localized file-size display string for the UI.
    public var displaySize: String {
        ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)
    }

    /// Creates a prepared photo attachment.
    ///
    /// - Parameters:
    ///   - id: Stable identity for SwiftUI lists.
    ///   - fileName: Filename sent in the multipart upload.
    ///   - mimeType: MIME type sent in the multipart upload.
    ///   - data: Encoded attachment bytes.
    public init(id: UUID, fileName: String, mimeType: String, data: Data) {
        self.id = id
        self.fileName = fileName
        self.mimeType = mimeType
        self.data = data
    }
}
#endif
