/// Why a file page opens a file read only (diff-host.md "Editor page", `readOnlyReason`).
nonisolated package enum FileReadOnlyReason: String, Sendable, Equatable {
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
