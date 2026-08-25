public import Foundation

/// One file staged in memory for the lifetime of a New Task composer session.
public struct TaskComposerAttachment: Identifiable, Equatable, Sendable {
    /// The supported attachment source kinds.
    public enum Kind: Equatable, Sendable {
        /// An image selected from the photo library.
        case image
        /// A document selected from Files.
        case file
    }

    /// Maximum number of staged attachments in one task.
    public static let maximumCount = 10
    /// Maximum encoded bytes for one staged image.
    public static let maximumImageBytes = 8 * 1024 * 1024
    /// Maximum raw bytes for one staged file.
    public static let maximumFileBytes = 32 * 1024 * 1024
    /// Maximum raw bytes across one task.
    public static let maximumTotalBytes = 64 * 1024 * 1024

    /// Stable upload identity retained across retries of the same task request.
    public let id: UUID
    /// Whether the staged value is an image or a general file.
    public let kind: Kind
    /// User-visible file name sent to the Mac for sanitization.
    public let displayName: String
    /// App-owned temporary file containing the bytes to upload.
    public let localStagedFileURL: URL
    /// Exact raw bytes in ``localStagedFileURL``.
    public let byteCount: Int
    /// Small encoded image preview, or `nil` for files.
    public let thumbnailData: Data?

    /// Creates one staged composer attachment.
    ///
    /// - Parameters:
    ///   - id: Stable upload identity retained across retries.
    ///   - kind: Whether the attachment is an image or file.
    ///   - displayName: User-visible file name.
    ///   - localStagedFileURL: App-owned temporary file containing the bytes.
    ///   - byteCount: Exact number of staged raw bytes.
    ///   - thumbnailData: Small encoded image preview, if available.
    public init(
        id: UUID = UUID(),
        kind: Kind,
        displayName: String,
        localStagedFileURL: URL,
        byteCount: Int,
        thumbnailData: Data? = nil
    ) {
        self.id = id
        self.kind = kind
        self.displayName = displayName
        self.localStagedFileURL = localStagedFileURL
        self.byteCount = byteCount
        self.thumbnailData = thumbnailData
    }

    /// Value-only identity captured by a task submission snapshot.
    public var submissionAttachment: MobileTaskSubmissionAttachment {
        MobileTaskSubmissionAttachment(uploadID: id, byteCount: byteCount)
    }
}
