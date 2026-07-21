import AppKit

/// Field editor that preserves raw pasteboard text until omnibar URL classification.
final class BrowserOmnibarPasteFieldEditor: NSTextView {
    override var isFieldEditor: Bool {
        get { true }
        set {}
    }

    override func readSelection(from pasteboard: NSPasteboard) -> Bool {
        guard let rawText = pasteboard.string(forType: .string) else {
            return super.readSelection(from: pasteboard)
        }

        let preparedText = BrowserURLResolver().textForPaste(rawText)
        guard preparedText != rawText else {
            return super.readSelection(from: pasteboard)
        }

        insertText(preparedText, replacementRange: selectedRange())
        return true
    }
}
