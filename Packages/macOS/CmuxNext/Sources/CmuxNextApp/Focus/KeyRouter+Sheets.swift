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
    /// first responder, or, while the keyboard is in the window's chrome
    /// (the sidebar list after a click), the focused pane's tab (a tab-scope
    /// dialog). Runs the dialog's Escape (its cancel button). Another tab's
    /// keys, and a text field's Escape, stay theirs.
    func cancelsBlockingDialog(_ event: NSEvent, in window: NSWindow?) -> Bool {
        guard Self.isBareEscape(event), let window,
              let id = CmuxDialogCenter.shared.dialogBlockingKeys(in: window, focusedArea: chromeFocusedPane(in: window))
        else { return false }
        return CmuxDialogCenter.shared.key(.escape, in: id)
    }

    /// The focused pane's view while the window's keyboard is in its chrome
    /// (no content and no text field has it); nil otherwise.
    private func chromeFocusedPane(in window: NSWindow) -> NSView? {
        let (controller, kind) = focus(for: window)
        guard kind == .content, let controller else { return nil }
        switch controller.focus.state.resolved {
        case .sidebar, .none: return controller.content?.focusedPane?.view
        default: return nil
        }
    }

    private static func isBareEscape(_ event: NSEvent) -> Bool {
        event.keyCode == ChordTracker.escapeKeyCode && event.modifierFlags.isDisjoint(with: [.command, .control, .option, .shift])
    }
}
