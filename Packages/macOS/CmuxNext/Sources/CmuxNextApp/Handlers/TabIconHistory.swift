import AppKit
import CmuxNextActions
import CmuxNextDaemon

/// Tab icon changes as undo steps (RECOVERABLE-BY-DEFAULT, like pins in
/// PINNED-ITEMS-END-TO-END P4): a user's set or remove registers its inverse on
/// the window's undo manager (Edit > Undo Set Tab Icon, Redo). Automation (CLI,
/// MCP, scripts, other clients, pages) does not touch the user's undo stack.
@MainActor
struct TabIconHistory {
    /// Sends one icon update for the tab `id` (a daemon tab id). False when the tab is gone.
    let apply: @MainActor (_ id: String, _ update: FieldUpdate<String>) -> Bool

    /// Changes the icon of tab `id` from `previous` to `icon` (nil removes it).
    func change(_ id: String, from previous: String?, to icon: String?, origin: ActionOrigin, undoManager: UndoManager?) {
        guard apply(id, icon.map { .set($0) } ?? .clear) else { return }
        guard origin == .user, previous != icon, let undoManager else { return }
        // Undo runs the inverse change, which registers the redo on the same manager.
        let record = PinUndoRecord { [self, weak undoManager] in change(id, from: icon, to: previous, origin: .user, undoManager: undoManager) }
        // The record is the target and the retained object, so it lives as long as the undo entry.
        undoManager.registerUndo(withTarget: record, selector: #selector(PinUndoRecord.run(_:)), object: record)
        undoManager.setActionName(icon == nil ? TabIconStrings.undoRemove : TabIconStrings.undoSet)
    }
}

/// Undo action names of tab icon changes (Handlers.xcstrings).
enum TabIconStrings {
    static var undoSet: String { String(localized: "tabIcon.undo.set", defaultValue: "Set Tab Icon", table: "Handlers", bundle: .module) }
    static var undoRemove: String {
        String(localized: "tabIcon.undo.remove", defaultValue: "Remove Tab Icon", table: "Handlers", bundle: .module)
    }
}
