public import Foundation

/// One attachment preserved with a saved composer draft. The raw bytes live
/// in a draft-owned file referenced by `relativePath`; resuming the draft
/// stages a fresh session copy so session teardown never touches the
/// draft-owned bytes.
public struct MobileTaskComposerDraftAttachment: Codable, Equatable, Sendable, Identifiable {
    /// Stable upload identity, shared with the live composer attachment.
    public let id: UUID
    /// Raw attachment kind; mirrors ``TaskComposerAttachment/Kind``.
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

extension TaskComposerAttachment.Kind {
    /// Stable persisted spelling of this kind.
    public var persistedValue: String {
        switch self {
        case .image: "image"
        case .file: "file"
        }
    }

    /// Restores a kind from its persisted spelling; unknown values decode as
    /// `.file` so a newer build's draft still restores as a plain document.
    public init(persistedValue: String) {
        self = persistedValue == "image" ? .image : .file
    }
}

extension TaskComposerAttachment {
    /// The preserved representation of this staged attachment.
    /// - Parameter relativePath: Draft-owned file path for the copied bytes.
    public func draftAttachment(relativePath: String) -> MobileTaskComposerDraftAttachment {
        MobileTaskComposerDraftAttachment(
            id: id,
            kind: kind.persistedValue,
            displayName: displayName,
            relativePath: relativePath,
            byteCount: byteCount,
            thumbnailData: thumbnailData
        )
    }
}
