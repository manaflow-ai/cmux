import AppKit
import CmuxNextDesign

// Sheets on cmux windows and cmux dialogs (`CmuxDialogCenter`, on the window's overlay) keep the keys that reach
// the window under them (the app was not active when one opened, the person clicked the window, or automation sent
// the key there): Escape cancels them, and a dialog answers any other key that is not a chord.
extension KeyRouter {
    /// Escape with no modifier that missed the sheet or the dialog blocking where the key landed: cancels it.
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

    /// Escape with no modifier where a cmux dialog blocks the keyboard: the whole window, the tab that holds the
    /// first responder, or the focused pane's tab while the keyboard is in the window's chrome (the sidebar list after
    /// a click) or the pane's Chromium page window. Runs its cancel button; another tab's keys stay theirs.
    func cancelsBlockingDialog(_ event: NSEvent, in window: NSWindow?) -> Bool {
        guard Self.isBareEscape(event), let window else { return false }
        let (host, area) = dialogKeyTarget(for: window)
        guard let id = CmuxDialogCenter.shared.dialogBlockingKeys(in: host, focusedArea: area) else { return false }
        return CmuxDialogCenter.shared.key(.escape, in: id)
    }

    /// Any other key that missed the dialog blocking where it landed goes to that dialog's keyboard, never the view
    /// under it (`CmuxDialogCenter.answersMissedKey`); a page window's key answers its pane's dialog, a chrome key not.
    func answersBlockingDialog(_ event: NSEvent, in window: NSWindow?) -> Bool {
        guard let window, CmuxDialogCenter.shared.showsDialog else { return false }
        let (host, area) = dialogKeyTarget(for: window)
        return CmuxDialogCenter.shared.answersMissedKey(event, in: host, focusedArea: host === window ? nil : area, keyWindow: window)
    }

    /// The cmux window whose dialogs a key in `window` may answer, and the focused pane's view when the keyboard is in
    /// no view of a tab: a Chromium page (or DevTools) child window, or the window's chrome (no content, no text field).
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
