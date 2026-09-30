import AppKit

/// The omnibar text field: a first click selects the whole URL (later
/// clicks place the caret), and the edit menu offers Paste and Go.
final class AddressField: ChromeTextField {
    var onFocus: (() -> Void)?
    var onPasteAndGo: (() -> Void)?
    var pasteAndGoTitle: (() -> String?)?

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted {
            (currentEditor() as? NSTextView)?.selectedTextAttributes = [.backgroundColor: OmnibarStyle.selection]
            onFocus?()
        }
        return accepted
    }

    override func mouseDown(with event: NSEvent) {
        // Chrome: clicking an unfocused omnibox selects everything instead
        // of placing the caret where the click landed.
        guard currentEditor() == nil, event.clickCount == 1 else { return super.mouseDown(with: event) }
        window?.makeFirstResponder(self)
    }

    /// The field editor's context menu (the field is its delegate).
    @objc func textView(_ textView: NSTextView, menu: NSMenu, for event: NSEvent, at charIndex: Int) -> NSMenu? {
        guard let title = pasteAndGoTitle?() else { return menu }
        let item = NSMenuItem(title: title, action: #selector(performPasteAndGo(_:)), keyEquivalent: "")
        item.target = self
        let paste = menu.items.firstIndex { $0.action == #selector(NSText.paste(_:)) }
        menu.insertItem(item, at: paste.map { $0 + 1 } ?? 0)
        return menu
    }

    @objc private func performPasteAndGo(_ sender: Any?) {
        onPasteAndGo?()
    }
}
