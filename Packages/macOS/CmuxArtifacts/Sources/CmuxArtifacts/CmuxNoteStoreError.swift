/// Errors surfaced by live Notes filesystem operations.
public enum CmuxNoteStoreError: Error, Equatable, Sendable {
    /// A note name was empty, unsafe, or not a Markdown path.
    case invalidName(String)
    /// No live note matched the requested name or path.
    case noteNotFound(String)
    /// More than one live note matched the requested name.
    case ambiguousNoteName(String, matches: [String])
    /// A note was not valid UTF-8 text.
    case invalidUTF8(String)
    /// A write or existing note exceeded the bounded Notes size limit.
    case noteTooLarge(actual: Int64, limit: Int64)
    /// The resolved note path escaped or crossed an untrusted filesystem entry.
    case pathOutsideStore(String)
}
