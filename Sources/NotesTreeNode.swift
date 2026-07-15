import Foundation

/// A single item in the Notes outline view.
///
/// `NotesTreeNode` is a reference type because `NSOutlineView` holds its items
/// by reference and compares them by identity. The full subtree is materialized
/// eagerly by ``NotesTreeStore`` (notes trees are small), so `children` is
/// non-nil for every directory node after a load.
// Nodes are built as an isolated snapshot off-main, then owned and mutated by NotesTreeStore on the main thread.
final class NotesTreeNode: Identifiable, @unchecked Sendable {
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
        case .pastFolder:
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
        case .pastFolder:
            return String(localized: "notes.tree.past", defaultValue: "Past")
        case .sessionFolder(let marker):
            // Titles come from transcripts and can be multiline pastes, which
            // a single-line label renders as blank; collapse for display.
            let trimmed = NotesTreeStorage.sanitizedSessionTitle(marker.title)
            return trimmed.isEmpty ? name : trimmed
        case .terminalFolder(let marker):
            if let activeSession = marker.activeSession {
                let title = NotesTreeStorage.sanitizedSessionTitle(activeSession.title)
                if !title.isEmpty { return title }
                if let agent = SessionAgent(rawValue: activeSession.agent) {
                    return agent.displayName
                }
                if !activeSession.agent.isEmpty { return activeSession.agent }
            }
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
