/// Mutation applied when writing a cmux Note.
public enum CmuxNoteWriteMode: Equatable, Sendable {
    /// Replace the note's complete UTF-8 contents.
    case replace
    /// Append UTF-8 text to the note, creating it when absent.
    case append
}
