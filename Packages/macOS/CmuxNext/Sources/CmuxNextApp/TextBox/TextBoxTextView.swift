import AppKit

/// The TextBox's editor: Return submits, Shift- or Option-Return adds a line, Escape gives the
/// keyboard back to the terminal and Shift-Tab changes the submit action. Keys an input method
/// is composing stay with it.
final class TextBoxTextView: NSTextView {
    var onSubmit: @MainActor () -> Void = {}
    var onEscape: @MainActor () -> Void = {}
    var onCycle: @MainActor () -> Void = {}

    override func keyDown(with event: NSEvent) {
        guard !hasMarkedText() else { return super.keyDown(with: event) }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch event.keyCode {
        case 36, 76: // Return, keypad Enter
            if !modifiers.isDisjoint(with: [.shift, .option]) { return insertNewlineIgnoringFieldEditor(nil) }
            if modifiers.isDisjoint(with: [.command, .control]) { return onSubmit() }
        case 53: // Escape
            return onEscape()
        case 48 where modifiers.contains(.shift): // Shift-Tab
            return onCycle()
        default:
            break
        }
        super.keyDown(with: event)
    }
}
