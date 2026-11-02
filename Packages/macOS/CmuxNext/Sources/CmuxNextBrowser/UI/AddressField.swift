import AppKit

/// The omnibar text field. It uses its own field editor
/// (`OmnibarFieldEditor`) and is the only `OmnibarFieldSurface`: the effect
/// applier writes it, nothing else does.
final class AddressField: ChromeTextField, OmnibarFieldSurface {
    var onFocus: (() -> Void)?
    var onPasteAndGo: (() -> Void)?
    var pasteAndGoTitle: (() -> String?)?
    /// The address bar's own items at the end of the context menu ("Always
    /// Show Full URLs", "Manage Search Engines…").
    var extraMenuItems: (() -> [NSMenuItem])?
    weak var sink: (any OmnibarFieldEditorSink)? {
        didSet { (cell as? AddressFieldCell)?.editor.sink = sink }
    }
    /// Bench marks (`debug.omnibar_bench`): nil outside a bench run.
    var probe: ((String) -> Void)? {
        didSet { (cell as? AddressFieldCell)?.editor.probe = probe }
    }

    override class var cellClass: AnyClass? {
        get { AddressFieldCell.self }
        set {}
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        // A URL field. Without a content type, AppKit's AutoFill heuristic
        // treats the focused field as a possible one-time-code field and
        // asks the ViewBridge service for a code list, synchronously on the
        // main thread; with no console session (headless test hosts) that
        // call blocks for seconds to minutes.
        contentType = .URL
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var editor: OmnibarFieldEditor? { currentEditor() as? OmnibarFieldEditor }
    private var isForwardingRightMouse = false
    /// The last written style, so a theme change can recolor the text.
    private var lastStyle: OmnibarPresentation.Style = .plain

    // AppKit refuses the keyboard to a selectable field that is not editable
    // (a read-only sign-in bar): Cmd-L would do nothing there. The bar still
    // takes it, to select and copy the address.
    override var acceptsFirstResponder: Bool { super.acceptsFirstResponder || (isEnabled && isSelectable) }

    override func textDidChange(_ notification: Notification) {
        super.textDidChange(notification)
        // The cell draws the placeholder under the editor: show or hide it with the text.
        needsDisplay = true
    }

    override func becomeFirstResponder() -> Bool {
        probe?("field.becomeFirstResponder")
        let accepted = super.becomeFirstResponder()
        probe?("field.becameFirstResponder")
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
        probe?("field.mouseDown")
        sink?.fieldEditorMouseDown(clickCount: event.clickCount, button: .left, word: nil)
        super.mouseDown(with: event)
        probe?("field.tracked")
        if event.omnibarDragged(to: NSApp.currentEvent) { sink?.fieldEditorMouseDragged() }
        sink?.fieldEditorMouseUp()
        probe?("field.mouseUpDone")
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

    /// The I-beam over the text at rest and while editing (`OmnibarPointer`);
    /// while editing the field editor adds its own I-beam over its text.
    override func resetCursorRects() {
        if isFieldEditorActive {
            super.resetCursorRects()
        } else {
            addCursorRect(bounds, cursor: OmnibarPointer.cursor(.text).cursor)
        }
        installedCursor = OmnibarPointer.cursor(.text)
    }

    /// The cursor AppKit last asked this field to install over its text
    /// (`debug.omnibar`): nil until AppKit built the field's cursor rects.
    private(set) var installedCursor: OmnibarPointer.Cursor?

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

    /// A density change sets the font in place, as a theme change recolors:
    /// the field editor keeps its text, selection and marked text, the
    /// resting text is written again. Writing the editor's text replaced it,
    /// which dropped an input method's composition and moved the caret.
    /// While editing this sets the font only: `text` and `style` apply to
    /// the resting field, so a new text or style goes through `write`.
    func restyle(_ text: String, style: OmnibarPresentation.Style) {
        let font = self.font ?? OmnibarStyle.font
        guard let editor = currentEditor() as? NSTextView else {
            write(text, style: style)
            return
        }
        if let storage = editor.textStorage {
            storage.addAttribute(.font, value: font, range: NSRange(location: 0, length: storage.length))
        }
        editor.typingAttributes[.font] = font
    }

    // theme-scoped: called only inside performWithTheme
    private func writeScoped(_ text: String, style: OmnibarPresentation.Style) {
        let font = font ?? OmnibarStyle.font
        if let editor = currentEditor() as? NSTextView {
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: OmnibarStyle.textPrimary]
            editor.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: attributes))
            editor.typingAttributes = attributes
            // The cell draws the placeholder under an empty editor (`EditorAlignedTextFieldCell`).
            needsDisplay = true
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
    @objc(textView:menu:forEvent:atIndex:) func textView(_ textView: NSTextView, menu: NSMenu, for event: NSEvent, at charIndex: Int) -> NSMenu? {
        if let title = pasteAndGoTitle?() {
            let item = NSMenuItem(title: title, action: #selector(performPasteAndGo(_:)), keyEquivalent: "")
            item.target = self
            let paste = menu.items.firstIndex { $0.action == #selector(NSText.paste(_:)) }
            menu.insertItem(item, at: paste.map { $0 + 1 } ?? 0)
        }
        let extras = extraMenuItems?() ?? []
        if !extras.isEmpty {
            menu.addItem(.separator())
            extras.forEach(menu.addItem)
        }
        return menu
    }

    @objc private func performPasteAndGo(_ sender: Any?) {
        onPasteAndGo?()
    }
}
