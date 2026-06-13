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

    /// Whether this kind is a directory (folder, session, or terminal folder).
    var isDirectory: Bool {
        switch self {
        case .folder, .sessionFolder, .terminalFolder:
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

/// A single item in the Notes outline view.
///
/// `NotesTreeNode` is a reference type because `NSOutlineView` holds its items
/// by reference and compares them by identity. The full subtree is materialized
/// eagerly by ``NotesTreeStore`` (notes trees are small), so `children` is
/// non-nil for every directory node after a load.
final class NotesTreeNode: Identifiable {
    /// Stable identity: the node's absolute filesystem path, or the synthetic
    /// `cmux-virtual-session://…` identity for live (unmaterialized) sessions.
    let id: String
    /// The on-disk basename (used for plain folders and notes).
    let name: String
    /// Absolute filesystem path to the file or directory. For virtual session
    /// rows this is the synthetic identity string, never an on-disk path —
    /// callers must check ``isVirtual`` before any filesystem operation.
    let path: String
    /// What this node represents.
    let kind: NotesTreeKind
    /// True for a live session row sourced from the agents' session stores
    /// (the Vault's scanners) with no backing folder yet. Acting on it (filing
    /// a note, dropping content) materializes a real session folder.
    let isVirtual: Bool
    /// Child nodes for directories; `nil` for notes.
    var children: [NotesTreeNode]?

    init(
        name: String,
        path: String,
        kind: NotesTreeKind,
        isVirtual: Bool = false,
        children: [NotesTreeNode]? = nil
    ) {
        self.id = path
        self.name = name
        self.path = path
        self.kind = kind
        self.isVirtual = isVirtual
        self.children = children
    }

    /// Whether the outline view can expand this node. Plain folders are always
    /// expandable — empty ones included — exactly like the Files tree's
    /// directories. Session rows behave like Vault rows until notes are filed
    /// under them: chevron (and click-to-expand) only once they have content,
    /// resume otherwise.
    var isExpandable: Bool {
        switch kind {
        case .folder:
            return true
        case .sessionFolder, .terminalFolder:
            return !(children?.isEmpty ?? true)
        case .note:
            return false
        }
    }

    /// The label shown in the sidebar. Session folders show their session title
    /// (which is friendlier than the slugified directory name); notes drop the
    /// `.md` extension; plain folders use their basename.
    var displayName: String {
        switch kind {
        case .sessionFolder(let marker):
            // Titles come from transcripts and can be multiline pastes, which
            // a single-line label renders as blank; collapse for display.
            let trimmed = NotesTreeStorage.sanitizedSessionTitle(marker.title)
            return trimmed.isEmpty ? name : trimmed
        case .terminalFolder(let marker):
            let trimmed = NotesTreeStorage.sanitizedSessionTitle(marker.title)
            return trimmed.isEmpty
                ? String(localized: "notes.tree.terminalRow.fallback", defaultValue: "Terminal")
                : trimmed
        case .note:
            return name.hasSuffix(".md") ? String(name.dropLast(3)) : name
        case .folder:
            return name
        }
    }
}
