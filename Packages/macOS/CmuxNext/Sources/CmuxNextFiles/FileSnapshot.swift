public import Foundation

/// Why a file page opens a file read only (diff-host.md "Editor page", `readOnlyReason`).
public nonisolated enum FileReadOnlyReason: String, Sendable, Equatable {
    /// No workspace root contains it.
    case outside
    /// Not valid UTF-8 (its text is a lossy decode that would not save back to the same bytes).
    case encoding
    /// A NUL byte in the first 8000 bytes, as git decides.
    case binary
    /// The file is not writable.
    case permission
    /// The host opened it as a chat transcript, which an edit could break (a chat's read-only open).
    case transcript
}

/// A file as a page gets it: the bytes decoded as UTF-8 with nothing removed (a BOM stays as
/// U+FEFF, every line ending stays), so writing the page's text back as UTF-8 reproduces the bytes.
public nonisolated struct FileSnapshot: Sendable, Equatable {
    /// The file's real path (links resolved).
    public let url: URL
    /// The decoded UTF-8 text.
    public let text: String
    /// SHA-256 of the bytes, lowercase hex.
    public let hash: String
    /// The byte count before decoding.
    public let size: Int
    /// The reason writing is disabled, if any.
    public let readOnlyReason: FileReadOnlyReason?

    /// Creates a snapshot of the exact decoded bytes and their access policy.
    public init(url: URL, text: String, hash: String, size: Int, readOnlyReason: FileReadOnlyReason?) {
        self.url = url
        self.text = text
        self.hash = hash
        self.size = size
        self.readOnlyReason = readOnlyReason
    }
}

/// The resulting content hash and whether a write was needed.
public nonisolated struct FileSaveResult: Sendable, Equatable {
    /// SHA-256 of the saved bytes.
    public let hash: String
    /// False when the bytes already equal the file's: nothing was written.
    public let written: Bool

    /// Creates a save receipt for the resulting bytes.
    public init(hash: String, written: Bool) {
        self.hash = hash
        self.written = written
    }
}
