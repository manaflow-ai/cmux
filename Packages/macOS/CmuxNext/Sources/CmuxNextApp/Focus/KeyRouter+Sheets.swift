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
