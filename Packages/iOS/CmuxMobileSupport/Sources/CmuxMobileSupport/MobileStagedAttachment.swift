public import Foundation

/// Exact app-owned bytes staged for a later explicit send or task creation.
public struct MobileStagedAttachment: Identifiable, Sendable, Equatable {
    /// The visual treatment used by attachment cards and previews.
    public enum Kind: Sendable, Equatable {
        /// An image selected from Photos or Files.
        case image
        /// Any other document selected from Files.
        case file
    }

    /// Maximum attachments in one composer draft.
    public static let maximumCount = 10
    /// Maximum bytes in one staged item.
    public static let maximumFileBytes = 32 * 1024 * 1024
    /// Maximum bytes across one composer draft.
    public static let maximumTotalBytes = 64 * 1024 * 1024
    /// Existing terminal image ceiling, retained while general files use the larger limit.
    public static let maximumImageBytes = 8 * 1024 * 1024

    /// Stable identity retained across upload retries.
    public let id: UUID
    /// Whether the item receives image or document treatment.
    public let kind: Kind
    /// Original user-visible basename, preserved exactly after removing path components.
    public let fileName: String
    /// App-owned file containing the exact bytes previewed and uploaded.
    public let localFileURL: URL
    /// Exact byte count in ``localFileURL``.
    public let byteCount: Int
    /// Small preview bytes when a caller already prepared one.
    public let thumbnailData: Data?

    /// Compatibility spelling used by the New Task UI.
    public var displayName: String { fileName }
    /// Compatibility spelling used by the New Task uploader.
    public var localStagedFileURL: URL { localFileURL }

    /// Creates an exact staged attachment.
    ///
    /// - Parameters:
    ///   - id: Stable identity retained across retries.
    ///   - kind: Image or document treatment.
    ///   - fileName: Original safe basename.
    ///   - localFileURL: App-owned file containing the exact staged bytes.
    ///   - byteCount: Exact byte count in `localFileURL`.
    ///   - thumbnailData: Optional small preview image.
    public init(
        id: UUID = UUID(),
        kind: Kind,
        fileName: String,
        localFileURL: URL,
        byteCount: Int,
        thumbnailData: Data? = nil
    ) {
        self.id = id
        self.kind = kind
        self.fileName = fileName
        self.localFileURL = localFileURL
        self.byteCount = byteCount
        self.thumbnailData = thumbnailData
    }

    /// Compatibility initializer for existing New Task call sites.
    public init(
        id: UUID = UUID(),
        kind: Kind,
        displayName: String,
        localStagedFileURL: URL,
        byteCount: Int,
        thumbnailData: Data? = nil
    ) {
        self.init(
            id: id,
            kind: kind,
            fileName: displayName,
            localFileURL: localStagedFileURL,
            byteCount: byteCount,
            thumbnailData: thumbnailData
        )
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id
            && lhs.kind == rhs.kind
            && lhs.fileName == rhs.fileName
            && lhs.localFileURL == rhs.localFileURL
            && lhs.byteCount == rhs.byteCount
    }
}
