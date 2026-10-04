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
    /// The file state the edits are based on, given by the participant at
    /// edit time (nil: the draft has only `fileModified` and `fileSize`).
    public var base: RecoveryDraftBase?

    public init(id: String, host: String = "local", title: String, savedAt: Date, contents: Data, filePath: String? = nil,
                fileModified: Date? = nil, fileSize: Int64? = nil, base: RecoveryDraftBase? = nil) {
        self.id = id
        self.host = host
        self.title = title
        self.savedAt = savedAt
        self.contents = contents
        self.filePath = filePath
        self.fileModified = fileModified
        self.fileSize = fileSize
        self.base = base
    }
}

/// The file state that a document's edits are based on: what the editor
/// read or last saved, not the file at the moment the draft is written.
/// Every field is optional; a field that is nil is not compared.
public nonisolated struct RecoveryDraftBase: Codable, Equatable, Sendable {
    public var modified: Date?
    public var size: Int64?
    /// Lowercase hex SHA-256 of the file's bytes. When present, it alone
    /// decides whether the file changed (a touch with the same bytes is no
    /// change).
    public var contentHash: String?

    public init(modified: Date? = nil, size: Int64? = nil, contentHash: String? = nil) {
        self.modified = modified
        self.size = size
        self.contentHash = contentHash
    }
}

/// Whether `update` kept a draft.
public nonisolated enum RecoveryDraftAcceptance: Equatable, Sendable {
    case kept
    /// Over the per-draft limit: no draft is written for this update.
    case tooLarge
    /// The id is not `file:<host id>:<absolute path>`, or the host or the
    /// path disagrees with it: no draft is written.
    case invalidID
}
