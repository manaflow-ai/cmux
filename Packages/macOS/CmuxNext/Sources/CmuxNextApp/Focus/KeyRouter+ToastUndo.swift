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
}
