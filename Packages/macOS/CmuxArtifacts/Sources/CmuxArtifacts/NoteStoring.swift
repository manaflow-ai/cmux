public import Foundation

/// Filesystem persistence seam for movable project Notes.
public protocol NoteStoring: Sendable {
    /// Lists Markdown notes from every live session `notes` directory.
    func listNotes(projectRoot: URL) async throws -> [CmuxProjectNote]
    /// Resolves an exact path, unique filename or stem, or unique fuzzy match.
    func resolveNote(projectRoot: URL, name: String) async throws -> CmuxProjectNote
    /// Reads one bounded UTF-8 note.
    func readNote(projectRoot: URL, name: String) async throws -> String
    /// Writes or appends one note in the current session filesystem.
    func writeNote(
        name: String,
        text: String,
        mode: CmuxNoteWriteMode,
        context: ArtifactCaptureContext
    ) async throws -> CmuxProjectNote
    /// Searches note filenames and bounded UTF-8 contents.
    func searchNotes(projectRoot: URL, query: String) async throws -> [CmuxNoteSearchResult]
    /// Deletes one resolved note without following symbolic links.
    func deleteNote(projectRoot: URL, name: String) async throws
}
