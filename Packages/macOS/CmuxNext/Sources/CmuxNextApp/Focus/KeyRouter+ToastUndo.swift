import AppKit
import CmuxNextDesign

// Cmd-Z and undo toasts (TOAST-UNDO-KEY, R96): the toast presenter decides
// whether Cmd-Z is the toast's (an undo toast shows and the focused
// responder has nothing to undo); the dispatcher asks it first, so Edit >
// Undo and the responder chain keep Cmd-Z otherwise.
extension KeyRouter {
    /// Cmd-Z with no other modifier in a window whose newest undo toast takes
    /// the key: runs it. Returns whether it did.
    func runsUndoToast(_ event: NSEvent, in window: NSWindow?) -> Bool {
        guard event.charactersIgnoringModifiers?.lowercased() == "z",
              event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command,
              let window, undoToasts.takesUndoKey(in: window) else { return false }
        return undoToasts.runUndo(in: window)
    }

    /// Cmd-Z or Shift-Cmd-Z in a window whose undo stack has a pin or
    /// sidebar step on top (`PinUndoStep`, after its toast hid): undoes or
    /// redoes it, as Edit > Undo would, also when the window is not key
    /// (Edit > Undo then has no target). Other undo stays the responders'.
    func runsUndoStep(_ event: NSEvent, in window: NSWindow?) -> Bool {
        guard event.charactersIgnoringModifiers?.lowercased() == "z", let window,
              let manager = window.firstResponder?.undoManager ?? window.undoManager else { return false }
        switch event.modifierFlags.intersection([.command, .control, .option, .shift]) {
        case .command:
            guard PinUndoStep.newest?.isTop(of: manager) == true else { return false }
            manager.undo()
            return true
        case [.command, .shift]:
            guard PinUndoStep.newestRedo?.isRedoTop(of: manager) == true else { return false }
            manager.redo()
            return true
        default:
            return false
        }
    }
}
