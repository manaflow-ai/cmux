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
    /// next toast (registered during an undo, its step becomes the redo).
    func registerUndo(title: String, _ inverse: @escaping @MainActor (PinCommands) -> Void) {
        let windows = context.services.windows
        guard let window = windows.active?.window ?? NSApp.keyWindow ?? NSApp.mainWindow ?? windows.controllers.last?.window else { return }
        let handle = CmuxToastCenter.shared.show(CmuxToast(id: Self.undoToastID, message: PinStrings.done(title), action: .undo()), in: window)
        let step = PinUndoStep(title: title) { inverse(self) }
        step.handle = handle
        step.undoManager = window.undoManager
        PinUndoStep.newest = step
        handle.onAction = { step.run(fromToast: true) }
        handle.ownsUndoTop = { [weak step] manager in step?.isTop(of: manager) == true }
        // The handler holds the step (an undo manager may not retain its target), so it outlives the toast.
        window.undoManager?.registerUndo(withTarget: step) { [step] _ in
            MainActor.assumeIsolated { step.run(fromToast: false) }
        }
        window.undoManager?.setActionName(title)
    }
}

/// One undo step shared by the toast and the window's undo stack: it runs
/// its inverse once, whichever path comes first.
@MainActor
final class PinUndoStep {
    /// The step registered last (a newer one is the top of its stack, not this).
    static weak var newest: PinUndoStep?
    private var inverse: (() -> Void)?
    private let title: String
    weak var handle: CmuxToastHandle?
    weak var undoManager: UndoManager?

    init(title: String, _ inverse: @escaping @MainActor () -> Void) {
        self.title = title
        self.inverse = inverse
    }

    /// Still to run, registered last, and the top of `manager` (its action name).
    func isTop(of manager: UndoManager?) -> Bool {
        guard let manager, inverse != nil, Self.newest === self, manager === undoManager else { return false }
        return manager.undoActionName == title
    }

    func run(fromToast: Bool) {
        guard let inverse else { return }
        self.inverse = nil
        if fromToast {
            undoManager?.removeAllActions(withTarget: self) // the toast ran it: the stack loses the step
        } else if let handle, !handle.isDismissed {
            handle.onAction = nil
            handle.dismiss() // the stack ran it: the toast goes
        }
        inverse()
    }
}
}
