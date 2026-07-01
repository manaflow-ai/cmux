import AppKit
import SwiftUI

/// The Notes sidebar tab: the Files tree and the Vault combined for one
/// workspace — a real filesystem tree of its notes (workspace subtree plus the
/// project's flat `.cmux/notes/*.md` notes) with the workspace's recent agent
/// sessions as live rows beneath them.
///
/// Backed by an `NSOutlineView` (not SwiftUI), so list rows never hold an
/// `ObservableObject` reference — sidestepping the lazy-list CPU-spin class of
/// bug (see CLAUDE.md snapshot-boundary rule). Cross-boundary actions that need
/// app state the tree doesn't own (opening a note panel, resuming a session) are
/// injected as closures from the composition root.
struct NotesTreePanelView: NSViewRepresentable {
    let store: NotesTreeStore
    /// Open a note file in a markdown surface.
    let onOpenNote: (NotesTreeNode, _ editImmediately: Bool) -> Void
    /// Resume the Claude session backing a session folder.
    let onResumeMarker: (NotesSessionMarker) -> Void
    /// Focus the terminal panel a terminal row points at.
    let onFocusTerminalPanel: (UUID) -> Void
    /// Resolve (and mint if needed) the note attachment target for a terminal row.
    let onResolveTerminalNoteTarget: (NotesTreeObservedTerminal) -> CmuxNoteAttachmentTarget?

    static let movePasteboardType = NSPasteboard.PasteboardType("com.cmux.notes-tree-move")
    /// Set on the drag pasteboard when the dragged item is a session folder, so
    /// the drop side can reject nesting a session under another session without
    /// reading the filesystem during drag-over.
    static let sessionFlagPasteboardType = NSPasteboard.PasteboardType("com.cmux.notes-tree-move.session")
    /// A draggable session pointer (`NotesSessionDescriptor` JSON). Written by
    /// both the Vault session rows and Notes session folders, so a claude/codex/
    /// any session drags identically; dropping it on the Notes tree creates a
    /// session folder. Shared with `SessionIndexView`.
    static let sessionDragPasteboardType = NSPasteboard.PasteboardType("com.cmux.session-drag")
    /// Bonsplit's external tab-drop payload. Session folders carry it so they
    /// can be dropped onto a pane to resume, exactly like a Vault row.
    static let tabTransferPasteboardType = NSPasteboard.PasteboardType("com.splittabbar.tabtransfer")

    /// Drag writer for note rows; see ``NotesTreeNoteDragWriter``.
    typealias NoteDragWriter = NotesTreeNoteDragWriter

    /// The outline's data source/delegate/action target; see
    /// ``NotesTreePanelCoordinator``.
    typealias Coordinator = NotesTreePanelCoordinator

    func makeCoordinator() -> Coordinator {
        Coordinator(
            store: store,
            onOpenNote: onOpenNote,
            onResumeMarker: onResumeMarker,
            onFocusTerminalPanel: onFocusTerminalPanel,
            onResolveTerminalNoteTarget: onResolveTerminalNoteTarget
        )
    }

    func makeNSView(context: Context) -> NotesTreeContainerView {
        let container = NotesTreeContainerView(coordinator: context.coordinator)
        context.coordinator.container = container
        return container
    }

    func updateNSView(_ container: NotesTreeContainerView, context: Context) {
        let coordinator = context.coordinator
        coordinator.store = store
        coordinator.onOpenNote = onOpenNote
        coordinator.onResumeMarker = onResumeMarker
        coordinator.onFocusTerminalPanel = onFocusTerminalPanel
        coordinator.onResolveTerminalNoteTarget = onResolveTerminalNoteTarget
        // Defer reloads while an inline rename is typing (reloadData would tear
        // the field editor down mid-edit); the rename's end flushes the miss.
        if container.appliedRevision != store.contentRevision, !coordinator.isRenaming {
            container.appliedRevision = store.contentRevision
            container.outlineView.reloadData()
            coordinator.applyExpansion(container.outlineView)
        }
        container.updateHeader(
            displayPath: store.headerDisplayPath,
            notesRootPath: store.resolvedRootPath,
            hasWorkspace: store.hasWorkspace
        )
        container.updateEmptyState(hasWorkspace: store.hasWorkspace, isEmpty: store.rootNodes.isEmpty)
    }
}
