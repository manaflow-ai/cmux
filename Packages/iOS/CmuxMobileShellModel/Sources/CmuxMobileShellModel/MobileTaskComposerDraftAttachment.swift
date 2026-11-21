public import Foundation

/// One attachment preserved with a saved composer draft. The raw bytes live
/// in a draft-owned file referenced by `relativePath`; resuming the draft
/// stages a fresh session copy so session teardown never touches the
/// draft-owned bytes.
public struct MobileTaskComposerDraftAttachment: Codable, Equatable, Sendable, Identifiable {
    /// Stable upload identity, shared with the live composer attachment.
    public let id: UUID
    /// Persisted attachment kind (`image` or `file`).
    public let kind: String
    /// User-visible file name.
    public let displayName: String
    /// Path of the preserved bytes relative to the drafts attachment root.
    public let relativePath: String
    /// Exact raw byte count of the preserved file.
    public let byteCount: Int
    /// Small encoded image preview, or `nil` for files.
    public let thumbnailData: Data?

    /// Creates one preserved draft attachment.
    public init(
        id: UUID,
        kind: String,
        displayName: String,
        relativePath: String,
        byteCount: Int,
        thumbnailData: Data? = nil
    ) {
        self.id = id
        self.kind = kind
        self.displayName = displayName
        self.relativePath = relativePath
        self.byteCount = byteCount
        self.thumbnailData = thumbnailData
    }
}
