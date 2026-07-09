import Foundation

// MARK: - Storage

/// Filesystem owner for the per-workspace Notes tree.
///
/// The tree is a real directory hierarchy rooted at
/// `<projectRoot>/.cmux/notes/<workspace-folder>/`. The filesystem is the source
/// of truth: notes are plain `.md` files, "moving" a note is a real
/// `FileManager` move, and session folders are real directories tagged by a
/// `_session.json` marker. This type performs no UI work and holds no state,
/// mirroring the app-target convention of ``NoteSupport``/``CmuxNoteStore``.
enum NotesTreeStorage {
    /// Marker filename binding a folder to a workspace.
    static let workspaceMarkerName = "_workspace.json"
    /// Marker filename tagging a directory as a Claude session folder.
    static let sessionMarkerName = "_session.json"
    static let markerDataReader = CmuxNoteIndexDataReader(maxBytes: 256 * 1024)




}
