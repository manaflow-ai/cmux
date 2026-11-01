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

    /// Pins or unpins the tab `id` (a daemon tab id), shown or not, on `machineID` when given (forks keep ids).
    func setTabPinned(_ id: String, pinned: Bool, origin: ActionOrigin, machineID: String? = nil) {
        guard apply(id, pinned: pinned, machineID: machineID) else { return }
        guard origin == .user else { return }
        registerUndo(title: pinned ? PinStrings.pinTab : PinStrings.unpinTab) { commands in
            commands.setTabPinned(id, pinned: !pinned, origin: .user, machineID: machineID)
        }
    }

    /// Sends the pin through the strip that shows the tab (its store
    /// intent), else straight to the daemon. False when the tab is gone.
    private func apply(_ id: String, pinned: Bool, machineID: String?) -> Bool {
        guard let (tab, pane) = context.targetTab(id, ActionInvocation().onMachine(machineID)) ?? context.refuseQuietly(RefusalStrings.noTab(id)) else { return false }
        if let controller = context.services.paneController(for: pane) {
            controller.setPinned(StripTabID(id), pinned: pinned)
        } else {
            let surface = tab.surface
            context.services.daemon(for: pane).send("set-tab-pinned") { _ = try await $0.setTabPinned(surface, pinned) }
        }
        return true
    }

    /// Puts a user's pin or sidebar change (a move, a reorder, a group's
    /// place, Pin, Add to Top) on the active window's undo stack: Edit > Undo
    /// and Cmd-Z run `inverse` once, like any macOS undo. No toast: these are
    /// not destructive and happen often (Lawrence 2026-10-18: the "Move Undo"
    /// toast "keeps on showing up every single time"). `inverse` registered
    /// during an undo fills the redo. Nil `inverse`: a change sent, not
    /// answered yet (`ToastUndoStep.pending`, cx-kpicb); the reply fills the step it returns.
    @discardableResult func registerUndo(title: String, filling: PinUndoStep? = nil, _ inverse: (@MainActor (PinCommands) -> Void)?) -> PinUndoStep? {
        let windows = context.services.windows
        guard let window = windows.active?.window ?? NSApp.keyWindow ?? NSApp.mainWindow ?? windows.controllers.last?.window else { return nil }
        guard let inverse else { return ToastUndoStep.pending(title: title, undoManager: window.undoManager, handle: nil) }
        return ToastUndoStep.attach(title: title, filling: filling, undoManager: window.undoManager, handle: nil) { inverse(self) }
    }
}

/// The pin and sidebar undo step (`ToastUndoStep`, in CmuxNextDesign with the toast it shares a step with).
typealias PinUndoStep = ToastUndoStep
