import AppKit
import CmuxNextDesign

// Sheets on cmux windows (save and open panels, confirmations) and cmux
// dialogs (`CmuxDialogCenter`, on the window's overlay): Escape ends them
// with Cancel even when the key reaches the window under them, not the
// sheet or the dialog (the app was not active when it opened, the person
// clicked the window, or automation sent the key to the window). AppKit
// and the dialog view handle Escape themselves when they have the keyboard.
extension KeyRouter {
    /// Escape with no modifier that missed the sheet or the dialog blocking
    /// where the key landed: cancels it. Returns whether it did.
    func cancelsMissedModal(_ event: NSEvent, in window: NSWindow?) -> Bool {
        cancelsAttachedSheet(event, in: window) || cancelsBlockingDialog(event, in: window)
    }

    /// Escape with no modifier in a window that shows a sheet the key did not
    /// reach: ends the sheet with `.cancel` (its completion runs, and
    /// `windowDidEndSheet` gives the keyboard back). Returns whether it did.
    func cancelsAttachedSheet(_ event: NSEvent, in window: NSWindow?) -> Bool {
        guard Self.isBareEscape(event), let window else { return false }
        return endTopmostSheet(window)
    }

    /// Escape with no modifier where a cmux dialog blocks the keyboard: the
    /// whole window (a window-scope dialog), the tab that holds the window's
    /// first responder, or the focused pane's tab (a tab-scope dialog) while
    /// the keyboard is in the window's chrome (the sidebar list after a
    /// click) or in the pane's Chromium page window. Runs the dialog's
    /// Escape (its cancel button). Another tab's keys, and a text field's
    /// Escape, stay theirs.
    func cancelsBlockingDialog(_ event: NSEvent, in window: NSWindow?) -> Bool {
        guard Self.isBareEscape(event), let window else { return false }
        let (host, area) = dialogKeyTarget(for: window)
        guard let id = CmuxDialogCenter.shared.dialogBlockingKeys(in: host, focusedArea: area) else { return false }
        return CmuxDialogCenter.shared.key(.escape, in: id)
    }

    /// A key that is not a chord and missed the cmux dialog blocking where it landed (the dialog's
    /// overlay did not have the keyboard): the dialog keyboard answers it (`CmuxDialogKeys`: Return
    /// presses the default button, Tab moves focus), and the view under the dialog never gets it
    /// (QA chrome-parity-v2-1: a Return and a typed line under the paste confirm reached the terminal
    /// it blocks). As for Escape, a page child window's key answers its pane's dialog; a key in the
    /// window's chrome (the sidebar list) stays the chrome's. Returns whether it consumed the key.
    func answersBlockingDialog(_ event: NSEvent, in window: NSWindow?) -> Bool {
        guard let window, CmuxDialogCenter.shared.showsDialog, !Self.isChord(event.modifierFlags) else { return false }
        let (host, area) = dialogKeyTarget(for: window)
        guard let id = CmuxDialogCenter.shared.dialogBlockingKeys(in: host, focusedArea: host === window ? nil : area) else { return false }
        // The dialog has the keyboard (its field or button in the window's top layer): AppKit delivers the key there.
        if let dialog = CmuxDialogCenter.shared.view(id), let responder = window.firstResponder as? NSView,
           responder === dialog || responder.isDescendant(of: dialog) { return false }
        _ = CmuxDialogCenter.shared.key(event, in: id)
        trace?("dialog: a key that missed the blocking dialog went to its keyboard")
        return true
    }

    /// The cmux window whose dialogs a key in `window` may answer, and the
    /// focused pane's view when the keyboard is in no view of a tab: a
    /// Chromium page (or DevTools) child window, which the focus follows to
    /// its pane, or the window's chrome (no content and no text field).
    private func dialogKeyTarget(for window: NSWindow) -> (NSWindow, NSView?) {
        let (controller, kind) = focus(for: window)
        guard kind == .content, let controller, let shell = controller.window else { return (window, nil) }
        let pane = controller.content?.focusedPane?.view
        if window !== shell { return (shell, pane) }
        switch controller.focus.state.resolved {
        case .sidebar, .none: return (shell, pane)
        default: return (shell, nil)
        }
    }

    private static func isBareEscape(_ event: NSEvent) -> Bool {
        event.keyCode == ChordTracker.escapeKeyCode && event.modifierFlags.isDisjoint(with: [.command, .control, .option, .shift])
    }
}
