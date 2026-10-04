public import Foundation

/// One recovery draft: the unsaved contents of a document, written on
/// every edit so a signal, crash or power-off never loses them.
public nonisolated struct RecoveryDraft: Codable, Equatable, Sendable {
    public var id: String
    /// The machine the document lives on: "local" for this Mac, else the
    /// Cloud or remote host id. A restore never writes a remote draft into
    /// a local file.
    public var host: String
    public var title: String
    public var savedAt: Date
    public var contents: Data
    /// The document's file, and its modification date and size when the
    /// draft was written (nil for an unsaved new document).
    public var filePath: String?
    public var fileModified: Date?
    public var fileSize: Int64?

    public init(id: String, host: String = "local", title: String, savedAt: Date, contents: Data, filePath: String? = nil,
                fileModified: Date? = nil, fileSize: Int64? = nil) {
        self.id = id
        self.host = host
        self.title = title
        self.savedAt = savedAt
        self.contents = contents
        self.filePath = filePath
        self.fileModified = fileModified
        self.fileSize = fileSize
    }
}

/// Whether `update` kept a draft.
public nonisolated enum RecoveryDraftAcceptance: Equatable, Sendable {
    case kept
    /// Over the per-draft limit: no draft is written for this update.
    case tooLarge
}
