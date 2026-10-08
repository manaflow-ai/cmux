import AppKit
import CmuxNextActions
import CmuxNextDaemon

/// Tab icon changes as undo steps (RECOVERABLE-BY-DEFAULT, the same as pins in
/// PINNED-ITEMS-END-TO-END P4): a user's set or remove offers its inverse as an
/// undo toast (its Undo button and Cmd-Z run it, which offers the next one).
/// Automation (CLI, MCP, scripts, other clients, pages) offers no undo.
@MainActor
struct TabIconHistory {
    /// Sends one icon update for the tab `id` (a daemon tab id). False when the tab is gone.
    let apply: @MainActor (_ id: String, _ update: FieldUpdate<String>) -> Bool
    /// Offers one undo step: a toast with `message` whose Undo runs `undo`.
    let offerUndo: @MainActor (_ message: String, _ undo: @escaping @MainActor () -> Void) -> Void

    /// Changes the icon of tab `id` from `previous` to `icon` (nil removes it).
    func change(_ id: String, from previous: String?, to icon: String?, origin: ActionOrigin) {
        guard apply(id, icon.map { .set($0) } ?? .clear) else { return }
        guard origin == .user, previous != icon else { return }
        // The undo is the inverse change, which offers the redo the same way.
        offerUndo(icon == nil ? TabIconStrings.undoRemove : TabIconStrings.undoSet) { [self] in
            change(id, from: icon, to: previous, origin: .user)
        }
    }
}

/// Undo toast messages of tab icon changes (Handlers.xcstrings).
enum TabIconStrings {
    static var undoSet: String { String(localized: "tabIcon.undo.set", defaultValue: "Tab Icon Set", table: "Handlers", bundle: .module) }
    static var undoRemove: String {
        String(localized: "tabIcon.undo.remove", defaultValue: "Tab Icon Removed", table: "Handlers", bundle: .module)
    }
}
