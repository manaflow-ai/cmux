import AppKit

/// The omnibar text field. It uses its own field editor
/// (`OmnibarFieldEditor`) and is the only `OmnibarFieldSurface`: the effect
/// applier writes it, nothing else does.
final class AddressField: ChromeTextField, OmnibarFieldSurface {
    var onFocus: (() -> Void)?
    var onPasteAndGo: (() -> Void)?
    var pasteAndGoTitle: (() -> String?)?
    weak var sink: (any OmnibarFieldEditorSink)? {
        didSet { (cell as? AddressFieldCell)?.editor.sink = sink }
    }

    override class var cellClass: AnyClass? {
        get { AddressFieldCell.self }
        set {}
    }

    var editor: OmnibarFieldEditor? { currentEditor() as? OmnibarFieldEditor }
    private var isForwardingRightMouse = false
    /// The last written style, so a theme change can recolor the text.
    private var lastStyle: OmnibarPresentation.Style = .plain

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted {
            performWithTheme {
                (currentEditor() as? NSTextView)?.selectedTextAttributes = [.backgroundColor: OmnibarStyle.selection]
            }
            onFocus?()
        }
        return accepted
    }

    override func mouseDown(with event: NSEvent) {
        // AppKit focuses the field and forwards the click to the field
        // editor (which reports the up); the focus coordinator sees the
        // responder change. Select-all on the focusing click is a state
        // machine rule.
        sink?.fieldEditorMouseDown(clickCount: event.clickCount, button: .left, word: nil)
        super.mouseDown(with: event)
        sink?.fieldEditorMouseUp()
    }

    /// A right-click on the unfocused omnibar focuses it and
    /// selects all before the context menu opens. The field editor then
    /// runs its own menu (with Paste and Go).
    override func rightMouseDown(with event: NSEvent) {
        // The field editor passes an unhandled right-click to its next
        // responder, this field: never forward it back.
        guard !isForwardingRightMouse else { return }
        isForwardingRightMouse = true
        defer { isForwardingRightMouse = false }
        sink?.fieldEditorMouseDown(clickCount: event.clickCount, button: .right, word: nil)
        if currentEditor() == nil { window?.makeFirstResponder(self) }
        if let editor = currentEditor() as? NSTextView {
            editor.rightMouseDown(with: event)
        } else {
            super.rightMouseDown(with: event)
        }
        sink?.fieldEditorMouseUp()
    }

    // MARK: OmnibarFieldSurface

    var isFieldEditorActive: Bool { currentEditor() != nil }
    var currentText: String { currentEditor()?.string ?? stringValue }
    var currentSelection: NSRange { currentEditor()?.selectedRange ?? NSRange(location: 0, length: 0) }
    var hasMarkedText: Bool { (currentEditor() as? NSTextView)?.hasMarkedText() ?? false }

    /// A theme change recolors the text in place: the field editor keeps
    /// its text and selection, the resting text is written again.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        if let editor = currentEditor() as? NSTextView {
            performWithTheme {
                let color = OmnibarStyle.textPrimary
                if let storage = editor.textStorage {
                    storage.addAttribute(.foregroundColor, value: color, range: NSRange(location: 0, length: storage.length))
                }
                editor.typingAttributes[.foregroundColor] = color
                editor.selectedTextAttributes = [.backgroundColor: OmnibarStyle.selection]
            }
        } else {
            write(stringValue, style: lastStyle)
        }
    }

    func write(_ text: String, style: OmnibarPresentation.Style) {
        performWithTheme { writeScoped(text, style: style) }
    }

    // theme-scoped: called only inside performWithTheme
    private func writeScoped(_ text: String, style: OmnibarPresentation.Style) {
        let font = font ?? OmnibarStyle.font
        if let editor = currentEditor() as? NSTextView {
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: OmnibarStyle.textPrimary]
            editor.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: attributes))
            editor.typingAttributes = attributes
            return
        }
        lastStyle = style
        switch style {
        case .plain:
            attributedStringValue = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: OmnibarStyle.textPrimary])
        case .compactURL(let url):
            let attributed = NSMutableAttributedString(string: text, attributes: [
                .font: font,
                .foregroundColor: OmnibarStyle.textSecondary,
            ])
            let host = BrowserURLDisplay.hostRange(in: text, for: url) ?? NSRange(location: 0, length: (text as NSString).length)
            attributed.addAttribute(.foregroundColor, value: OmnibarStyle.textPrimary, range: host)
            attributedStringValue = attributed
        }
    }

    func select(_ range: NSRange) {
        guard let editor = currentEditor() as? NSTextView else { return }
        editor.setSelectedRange(range)
        if range.length == 0 { editor.scrollRangeToVisible(range) }
    }

    // MARK: Paste and Go

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
