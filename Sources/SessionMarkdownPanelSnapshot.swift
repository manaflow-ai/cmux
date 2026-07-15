import Foundation

struct SessionMarkdownPanelSnapshot: Codable, Sendable {
    var filePath: String
    var displayMode: MarkdownPanelDisplayMode? = nil
    /// When present, this markdown panel was opened as a project-scoped note.
    /// On restore the note is re-resolved against the workspace project root
    /// (`.cmux/notes/<noteSlug>.md`) so the panel survives the project moving
    /// to a different absolute path.
    var noteSlug: String? = nil
    var noteID: String? = nil
    /// Relative path under `.cmux/` for indexed notes, e.g. `notes/<note-id>.md`.
    /// Legacy slug notes omit this and restore through `noteSlug`.
    var noteBodyPath: String? = nil
    /// Display title from the indexed note record, preserved for restored tabs.
    var noteTitle: String? = nil
}
