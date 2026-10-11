import Foundation

/// Why a file page opens a file read only (diff-host.md "Editor page", `readOnlyReason`).
nonisolated enum FileReadOnlyReason: String, Sendable, Equatable {
    /// No workspace root contains it.
    case outside
    /// Not valid UTF-8 (its text is a lossy decode that would not save back to the same bytes).
    case encoding
    /// A NUL byte in the first 8000 bytes, as git decides.
    case binary
    /// The file is not writable.
    case permission
}

/// A file as a page gets it: the bytes decoded as UTF-8 with nothing removed (a BOM stays as
/// U+FEFF, every line ending stays), so writing the page's text back as UTF-8 reproduces the bytes.
nonisolated struct FileSnapshot: Sendable, Equatable {
    /// The file's real path (links resolved).
    let url: URL
    let text: String
    /// SHA-256 of the bytes, lowercase hex.
    let hash: String
    let size: Int
    let readOnlyReason: FileReadOnlyReason?
}

nonisolated struct FileSaveResult: Sendable, Equatable {
    let hash: String
    /// False when the bytes already equal the file's: nothing was written.
    let written: Bool
}
