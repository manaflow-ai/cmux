import Foundation

/// Filename or bounded-content match returned by Notes search.
public struct CmuxNoteSearchResult: Identifiable, Equatable, Sendable {
    /// Result identity equal to the note's current relative path.
    public let id: String
    /// Matched live note value.
    public let note: CmuxProjectNote
    /// Whether the note's UTF-8 content matched the query.
    public let matchedContent: Bool
    /// Bounded single-line content excerpt, when available.
    public let snippet: String?

    /// Creates a Notes search result.
    ///
    /// - Parameters:
    ///   - note: Matched live note value.
    ///   - matchedContent: Whether note contents matched.
    ///   - snippet: Bounded single-line content excerpt.
    public init(note: CmuxProjectNote, matchedContent: Bool, snippet: String?) {
        self.id = note.id
        self.note = note
        self.matchedContent = matchedContent
        self.snippet = snippet
    }
}
