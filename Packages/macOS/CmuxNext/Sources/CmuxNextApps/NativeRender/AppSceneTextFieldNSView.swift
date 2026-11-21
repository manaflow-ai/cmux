import AppKit
import CmuxNextDesign

/// `TextField`: a themed, unboxed field (its text, caret and placeholder in the scope's inks). The
/// text is local while the person types; with `onEdit` each change sends `edit {text}`; Return sends
/// `submit {text}` and Escape `cancel`. A new `text` from the app replaces the field's text.
/// `autofocus` takes the keyboard when the field first shows.
final class AppSceneTextFieldNSView: AppSceneNodeNSView, NSTextFieldDelegate {
    private let field = ThemedTextField()
    /// The last `text` prop applied, so an unrelated update does not reset what the person typed.
    private var appliedText: String?
    private var focusedOnce = false

    override init(id: String, node: AppSceneNode) {
        super.init(id: id, node: node)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.fill = { .clear }
        field.font = Typography.body
        field.lineBreakMode = .byTruncatingTail
        field.usesSingleLineMode = true
        field.cell?.sendsActionOnEndEditing = false
        field.target = self
        field.action = #selector(submitted)
        field.delegate = self
        addSubview(field)
    }

    override func configure(_ node: AppSceneNode) {
        super.configure(node)
        field.placeholderString = node.string("placeholder")
        field.isEnabled = !node.flag("disabled")
        let text = node.string("text") ?? ""
        if text != appliedText {
            appliedText = text
            if field.stringValue != text { field.stringValue = text }
        }
        field.setAccessibilityLabel(node.string("placeholder"))
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window, node.flag("autofocus"), !focusedOnce else { return }
        focusedOnce = true
        window.makeFirstResponder(field)
    }

    @objc private func submitted() { send("submit", ["text": .string(field.stringValue)]) }

    func controlTextDidChange(_ obj: Notification) {
        guard node.flag("onEdit") else { return }
        send("edit", ["text": .string(field.stringValue)])
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard commandSelector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        send("cancel")
        return true
    }

    override func contentHeight(width: CGFloat) -> CGFloat { max(18, ceil(field.intrinsicContentSize.height)) }

    override func layoutContent(in rect: CGRect) {
        let height = ceil(field.intrinsicContentSize.height)
        field.frame = CGRect(x: rect.minX, y: rect.midY - height / 2, width: rect.width, height: height).integral
    }

    override func paint() { field.applyThemeColors() }
}
