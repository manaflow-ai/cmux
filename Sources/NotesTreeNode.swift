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
    /// A directory backed by a Claude session, carrying its resume metadata.
    case sessionFolder(NotesSessionMarker)

    /// Whether this kind is a directory (folder or session folder).
    var isDirectory: Bool {
        switch self {
        case .folder, .sessionFolder:
            return true
        case .note:
            return false
        }
    }
}

/// A single item in the Notes outline view.
///
/// `NotesTreeNode` is a reference type because `NSOutlineView` holds its items
/// by reference and compares them by identity. The full subtree is materialized
/// eagerly by ``NotesTreeStore`` (notes trees are small), so `children` is
/// non-nil for every directory node after a load.
final class NotesTreeNode: Identifiable {
    /// Stable identity: the node's absolute filesystem path.
    let id: String
    /// The on-disk basename (used for plain folders and notes).
    let name: String
    /// Absolute filesystem path to the file or directory.
    let path: String
    /// What this node represents.
    let kind: NotesTreeKind
    /// Child nodes for directories; `nil` for notes.
    var children: [NotesTreeNode]?

    init(name: String, path: String, kind: NotesTreeKind, children: [NotesTreeNode]? = nil) {
        self.id = path
        self.name = name
        self.path = path
        self.kind = kind
        self.children = children
    }

    /// Whether the outline view can expand this node.
    var isExpandable: Bool { kind.isDirectory }

    /// The label shown in the sidebar. Session folders show their session title
    /// (which is friendlier than the slugified directory name); notes drop the
    /// `.md` extension; plain folders use their basename.
    var displayName: String {
        switch kind {
        case .sessionFolder(let marker):
            let trimmed = marker.title.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? name : trimmed
        case .note:
            return name.hasSuffix(".md") ? String(name.dropLast(3)) : name
        case .folder:
            return name
        }
    }
}
