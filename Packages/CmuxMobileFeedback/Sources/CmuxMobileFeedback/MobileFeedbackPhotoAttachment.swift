#if os(iOS)
import Foundation

public struct MobileFeedbackPhotoAttachment: Identifiable, Sendable {
    public let id: UUID
    public let fileName: String
    public let mimeType: String
    public let data: Data

    public var displaySize: String {
        ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)
    }

    public init(id: UUID, fileName: String, mimeType: String, data: Data) {
        self.id = id
        self.fileName = fileName
        self.mimeType = mimeType
        self.data = data
    }
}
#endif
