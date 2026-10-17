import AppKit

/// Field editor that preserves raw pasteboard text until omnibar URL classification, and adds
/// "Paste and Go" to its right-click menu for a delegate that handles it.
final class BrowserOmnibarPasteFieldEditor: NSTextView {
    override var isFieldEditor: Bool {
        get { true }
        set {}
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        pasteAndGoMenu(from: super.menu(for: event), pasteboard: .general)
    }

    /// `base` with the Paste and Go row when the delegate handles it and `pasteboard` has text.
    /// - Parameters:
    ///   - base: The text view's menu.
    ///   - pasteboard: The pasteboard the row pastes from.
    /// - Returns: The menu to show.
    func pasteAndGoMenu(from base: NSMenu?, pasteboard: NSPasteboard) -> NSMenu? {
        pasteAndGoMenu(from: base, pasteboardText: pasteboard.string(forType: .string))
    }

    /// ``pasteAndGoMenu(from:pasteboard:)`` for the pasteboard's text.
    func pasteAndGoMenu(from base: NSMenu?, pasteboardText: String?) -> NSMenu? {
        guard let base, isEditable,
              let handler = delegate as? any BrowserOmnibarPasteAndGoHandling,
              let row = BrowserOmnibarPasteAndGo.row(forPasteboardText: pasteboardText) else {
            return base
        }
        return BrowserOmnibarPasteAndGo.menu(adding: row, to: base) { [weak handler] text in
            handler?.omnibarPasteAndGo(text)
        }
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
