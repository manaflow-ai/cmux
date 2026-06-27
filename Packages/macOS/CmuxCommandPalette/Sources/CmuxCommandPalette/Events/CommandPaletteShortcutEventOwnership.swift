public import AppKit

/// Decides whether a routed key event belongs to the command-palette window and
/// whether that window's field editor is mid-IME-composition.
///
/// The app's global shortcut monitor consults this before routing a key event so
/// the palette window keeps ownership of its own keystrokes (including Escape and
/// Return while an input-method candidate list is composing marked text). It wraps
/// the optional palette window the monitor resolved for the event; both questions
/// answer `false` when there is no palette window.
@MainActor
public struct CommandPaletteShortcutEventOwnership {
    /// The command-palette window resolved for the event being routed, if any.
    public let paletteWindow: NSWindow?

    /// Creates an ownership probe for the given palette window.
    public init(paletteWindow: NSWindow?) {
        self.paletteWindow = paletteWindow
    }

    /// Whether the routed shortcut event belongs to the command-palette window.
    ///
    /// Matches by the event's own window first, then by window number, and finally
    /// falls back to the key window when the event carries no window association.
    public func ownsShortcutEvent(_ event: NSEvent) -> Bool {
        guard let paletteWindow else { return false }
        if let eventWindow = event.window {
            return eventWindow === paletteWindow
        }
        let eventWindowNumber = event.windowNumber
        if eventWindowNumber > 0 {
            return eventWindowNumber == paletteWindow.windowNumber
        }
        if let keyWindow = NSApp.keyWindow {
            return keyWindow === paletteWindow
        }
        return false
    }

    /// Whether the palette window's field editor currently holds marked text, i.e.
    /// an input method is composing inside the palette's text field.
    public var fieldEditorHasMarkedText: Bool {
        guard let paletteWindow else { return false }
        if let editor = paletteWindow.firstResponder as? NSTextView {
            return editor.hasMarkedText()
        }
        if let textField = paletteWindow.firstResponder as? NSTextField,
           let editor = textField.currentEditor() as? NSTextView {
            return editor.hasMarkedText()
        }
        return false
    }
}
