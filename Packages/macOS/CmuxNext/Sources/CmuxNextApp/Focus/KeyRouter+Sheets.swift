import AppKit

// Sheets on cmux windows (save and open panels, confirmations): Escape ends
// them with Cancel even when the key reaches the window under the sheet,
// not the sheet (the app is not active, or automation sent the key to the
// window). AppKit handles Escape itself when the sheet is the key window.
extension KeyRouter {
    /// Escape with no modifier in a window that shows a sheet the key did not
    /// reach: ends the sheet with `.cancel` (its completion runs, and
    /// `windowDidEndSheet` gives the keyboard back). Returns whether it did.
    func cancelsAttachedSheet(_ event: NSEvent, in window: NSWindow?) -> Bool {
        guard event.keyCode == ChordTracker.escapeKeyCode,
              event.modifierFlags.isDisjoint(with: [.command, .control, .option, .shift]),
              let window, window.attachedSheet != nil else { return false }
        return SheetDismissal.endTopmost(of: window)
    }
}
