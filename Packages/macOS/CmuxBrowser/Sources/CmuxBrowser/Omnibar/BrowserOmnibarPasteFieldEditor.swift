import AppKit

/// Field editor that preserves raw pasteboard text until omnibar URL classification.
final class BrowserOmnibarPasteFieldEditor: NSTextView {
    override var isFieldEditor: Bool {
        get { true }
        set {}
    }

    override func readSelection(from pasteboard: NSPasteboard) -> Bool {
        guard insertPreparedText(from: pasteboard, type: .string) else {
            return super.readSelection(from: pasteboard)
        }

        return true
    }

    override func readSelection(
        from pasteboard: NSPasteboard,
        type: NSPasteboard.PasteboardType
    ) -> Bool {
        guard insertPreparedText(from: pasteboard, type: type) else {
            return super.readSelection(from: pasteboard, type: type)
        }

        return true
    }

    private func insertPreparedText(
        from pasteboard: NSPasteboard,
        type: NSPasteboard.PasteboardType
    ) -> Bool {
        guard type == .string, let rawText = pasteboard.string(forType: type) else { return false }

        let preparedText = BrowserURLResolver().textForPaste(rawText)
        guard preparedText != rawText else { return false }

        insertText(preparedText, replacementRange: selectedRange())
        return true
    }
}
