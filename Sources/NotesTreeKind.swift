import Foundation

/// What a node in the Notes tree represents.
///
/// A directory is a *session folder* iff it contains a `_session.json` marker
/// (see ``NotesTreeStorage/sessionMarkerName``); otherwise it is a plain
/// ``folder``. Regular `.md` files are ``note``s. Everything else (dotfiles,
/// the `_workspace.json`/`_session.json` markers, non-markdown files) is hidden
/// from the tree and never produces a node.
enum NotesTreeKind: Equatable, Sendable {
    /// A plain user-created directory.
    case folder
    /// A markdown note file.
    case note
    /// A directory backed by an agent session, carrying its resume metadata.
    case sessionFolder(NotesSessionMarker)
    /// A live terminal pane in this workspace (always virtual): a pointer row
    /// that focuses its panel, with the pane's attached notes and observed
    /// agent sessions nested beneath it.
    case terminalFolder(NotesTreeObservedTerminal)
    /// Historical workspace sessions that are no longer observed in a live
    /// terminal. Purely virtual; it never creates or moves files.
    case pastFolder

    /// Whether this kind is a directory (folder, session, or terminal folder).
    var isDirectory: Bool {
        switch self {
        case .folder, .sessionFolder, .terminalFolder, .pastFolder:
            return true
        case .note:
            return false
        }
    }

    /// The session marker when this is a session folder, else `nil`.
    var sessionMarker: NotesSessionMarker? {
        if case .sessionFolder(let marker) = self { return marker }
        return nil
    }

    /// The terminal observation when this is a terminal row, else `nil`.
    var terminalMarker: NotesTreeObservedTerminal? {
        if case .terminalFolder(let marker) = self { return marker }
        return nil
    }
}
