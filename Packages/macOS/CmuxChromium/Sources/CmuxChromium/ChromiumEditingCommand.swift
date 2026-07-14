/// A standard document editing command cmux executes inside a Chromium page.
///
/// Blink on macOS only performs Command-key editing shortcuts when the
/// embedder attaches edit commands to the forwarded key event, which the OWL
/// wire protocol does not expose yet. cmux instead recognizes the standard
/// macOS editing key equivalents (and Edit-menu actions) on
/// ``ChromiumWebView`` and executes the matching command through JavaScript
/// in the session's focused document.
public enum ChromiumEditingCommand: Sendable, Equatable, CaseIterable {
    /// Select all content in the focused document or text control (⌘A).
    case selectAll
    /// Copy the current selection to the system pasteboard (⌘C).
    case copy
    /// Cut the current selection to the system pasteboard (⌘X).
    case cut
    /// Insert the system pasteboard's plain-text contents (⌘V / ⇧⌘V).
    case paste
    /// Undo the last editing operation in the focused document (⌘Z).
    case undo
    /// Redo the last undone editing operation (⇧⌘Z).
    case redo

    /// Maps one macOS key equivalent to its editing command.
    ///
    /// Returns `nil` for every chord the command should not claim: events
    /// without Command, events with Option or Control (those stay available
    /// to cmux shortcuts and the main menu), and unrecognized keys.
    ///
    /// - Parameters:
    ///   - characters: `NSEvent.charactersIgnoringModifiers` for the event.
    ///   - command: Whether the Command modifier is pressed.
    ///   - shift: Whether the Shift modifier is pressed.
    ///   - option: Whether the Option modifier is pressed.
    ///   - control: Whether the Control modifier is pressed.
    public init?(characters: String?, command: Bool, shift: Bool, option: Bool, control: Bool) {
        guard command, !option, !control else { return nil }
        switch characters?.lowercased() {
        case "a" where !shift:
            self = .selectAll
        case "c" where !shift:
            self = .copy
        case "x" where !shift:
            self = .cut
        case "v":
            // ⇧⌘V (Paste and Match Style) folds into plain paste: the
            // JavaScript insertText path only inserts plain text anyway.
            self = .paste
        case "z":
            self = shift ? .redo : .undo
        default:
            return nil
        }
    }
}
