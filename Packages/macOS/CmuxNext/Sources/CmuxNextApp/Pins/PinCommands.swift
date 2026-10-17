import AppKit
import CmuxNextActions
import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextDesign

/// The one path every tab pin and unpin takes (PINNED-ITEMS-END-TO-END):
/// the palette, the tab menu, the CLI and MCP all run `palette.toggleTabPin`,
/// which calls this. The daemon owns the pin (`tab.pin` / `tab.unpin`); a
/// user's pin is also an undo step (P4, RECOVERABLE-BY-DEFAULT): Edit >
/// Undo Pin Tab sends the inverse op, and Redo sends it again. Automation
/// pins are not put on the user's undo stack.
@MainActor
struct PinCommands {
    let context: AppActionContext

    /// Pins or unpins the tab `id` (a daemon tab id), shown or not.
    func setTabPinned(_ id: String, pinned: Bool, origin: ActionOrigin) {
        guard apply(id, pinned: pinned) else { return }
        guard origin == .user else { return }
        registerUndo(title: pinned ? PinStrings.pinTab : PinStrings.unpinTab) { commands in
            commands.setTabPinned(id, pinned: !pinned, origin: .user)
        }
    }

    /// Sends the pin through the strip that shows the tab (its store
    /// intent), else straight to the daemon. False when the tab is gone.
    private func apply(_ id: String, pinned: Bool) -> Bool {
        guard let (tab, pane) = context.services.locateTab(id) ?? context.refuseQuietly(RefusalStrings.noTab(id)) else { return false }
        if let controller = context.services.paneController(for: pane) {
            controller.setPinned(StripTabID(id), pinned: pinned)
        } else {
            let surface = tab.surface
            context.send("set-tab-pinned") { _ = try await $0.setTabPinned(surface, pinned) }
        }
        return true
    }

    /// The id of the pin undo toast (one per window; a newer pin change replaces it).
    static let undoToastID = "pin-undo"

    /// Shows the undo toast for a user's pin or sidebar change in the active
    /// window and puts the same step on the window's undo stack. The toast
    /// only hides after its time: Edit > Undo and Cmd-Z still undo the step
    /// later, like any macOS undo. While the toast shows, its Undo button and
    /// Cmd-Z (TOAST-UNDO-KEY, or the undo stack when it holds the step) run
    /// `inverse` once; the other path then does nothing. `inverse` shows the
    /// next toast (registered during an undo, its step becomes the redo). Nil `inverse`: a change sent, not answered yet
    /// (`ToastUndoStep.pending`, cx-kpicb); the reply fills the step it returns.
    @discardableResult func registerUndo(title: String, filling: PinUndoStep? = nil, _ inverse: (@MainActor (PinCommands) -> Void)?) -> PinUndoStep? {
        let windows = context.services.windows
        guard let window = windows.active?.window ?? NSApp.keyWindow ?? NSApp.mainWindow ?? windows.controllers.last?.window else { return nil }
        let handle = CmuxToastCenter.shared.show(CmuxToast(id: Self.undoToastID, message: PinStrings.done(title), action: .undo()), in: window)
        guard let inverse else { return ToastUndoStep.pending(title: title, undoManager: window.undoManager, handle: handle) }
        return ToastUndoStep.attach(title: title, filling: filling, undoManager: window.undoManager, handle: handle) { inverse(self) }
    }
}

/// The pin and sidebar undo step (`ToastUndoStep`, in CmuxNextDesign with the toast it shares a step with).
typealias PinUndoStep = ToastUndoStep
