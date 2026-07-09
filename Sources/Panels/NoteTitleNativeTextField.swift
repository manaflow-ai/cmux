import AppKit

/// Borderless single-line `NSTextField` backing the note-title rename control,
/// keeping the I-beam cursor across its full bounds.
final class NoteTitleNativeTextField: NSTextField {
    /// Runs before the field claims first responder on click, so the host can
    /// route pane focus to this panel first (otherwise the focus system can
    /// steal the responder right back and the click appears to do nothing).
    var onBeginEditingClick: (() -> Void)?

    /// Editing may only start from a real click on the title. Without this,
    /// AppKit's automatic first-responder assignment (key-view loop, focus
    /// restoration after pane churn, a failed body-focus on note open) lands
    /// in the always-editable field and leaves a blinking insertion caret in
    /// the header.
    private var allowsFocusFromClick = false

    override var acceptsFirstResponder: Bool {
        allowsFocusFromClick && super.acceptsFirstResponder
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        isBezeled = false
        drawsBackground = false
        focusRingType = .none
        usesSingleLineMode = true
        lineBreakMode = .byTruncatingTail
        cell?.wraps = false
        cell?.truncatesLastVisibleLine = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .iBeam)
    }

    /// Begin editing on the click that activates the pane, instead of
    /// requiring a second click once focus has settled.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        onBeginEditingClick?()
        allowsFocusFromClick = true
        if window?.firstResponder !== currentEditor() {
            window?.makeFirstResponder(self)
        }
        super.mouseDown(with: event)
    }

    override func textDidEndEditing(_ notification: Notification) {
        super.textDidEndEditing(notification)
        allowsFocusFromClick = false
    }
}
