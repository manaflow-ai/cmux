// cmux: the remove button an inline attachment shows on hover (Draft+InlineMarks.swift). Not a vendored file.
import AppKit

/// The remove button at the top right of the inline attachment under the pointer. TextKit 2 draws
/// the field's attachments itself and did not place `ComposeInlineAttachmentView` (with its own
/// hover button) in the field, so the field tracks the pointer over its attachments instead
/// (Austin 2026-10-20: hovering a pasted picture showed no remove button).
final class ComposeInlineRemoveHover: NSObject {
    private weak var field: NSTextView?
    let button = ComposeInlineRemoveButton()
    /// The attachment the button removes (under the pointer).
    private(set) weak var hovered: ComposeInlineAttachment?
    /// The field's tracking area for the pointer (it does not keep its owner, so it leaves with this).
    private var tracking: NSTrackingArea?

    deinit {
        if let tracking { field?.removeTrackingArea(tracking) }
    }

    /// Adds the button and the pointer tracking to FIELD.
    func install(on field: NSTextView) {
        self.field = field
        button.onPress = { [weak self] in self?.removeClicked() }
        button.isHidden = true
        field.addSubview(button)
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        field.addTrackingArea(area)
        tracking = area
    }

    /// The field's attachments with their boxes in the field's coordinates, in text order.
    func attachmentRects() -> [(attachment: ComposeInlineAttachment, rect: CGRect)] {
        guard let field, let storage = field.textStorage, let tlm = field.textLayoutManager, let tcm = tlm.textContentManager else { return [] }
        let origin = field.textContainerOrigin
        var out: [(ComposeInlineAttachment, CGRect)] = []
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { v, r, _ in
            guard let a = v as? ComposeInlineAttachment,
                  let start = tcm.location(tcm.documentRange.location, offsetBy: r.location),
                  let end = tcm.location(start, offsetBy: r.length),
                  let range = NSTextRange(location: start, end: end) else { return }
            var segment: CGRect?
            tlm.enumerateTextSegments(in: range, type: .standard, options: [.rangeNotRequired]) { _, f, _, _ in
                segment = f
                return false
            }
            // The picture is its line's only thing, at the line's top left (ComposeInlineAttachment).
            guard let s = segment else { return }
            out.append((a, CGRect(x: s.minX + origin.x, y: s.minY + origin.y, width: min(s.width, a.pictureSize.width),
                                  height: min(s.height, a.pictureSize.height))))
        }
        return out
    }

    /// The pointer is at POINT in the field: the button shows on the attachment there, or hides.
    func pointerMoved(to point: CGPoint) {
        if !button.isHidden, button.frame.contains(point) { return }
        guard let hit = attachmentRects().first(where: { $0.rect.contains(point) }), !hit.attachment.showsOwnView else { hide(); return }
        let s = ComposeAttachmentStrip.removeSize
        let r = hit.rect
        button.frame = CGRect(x: r.maxX - s - 4, y: field?.isFlipped == false ? r.maxY - s - 4 : r.minY + 4, width: s, height: s)
        hovered = hit.attachment
        button.isHidden = false
    }

    func hide() {
        button.isHidden = true
        hovered = nil
    }

    // The tracking area's owner gets these as `mouseMoved:` and the rest (explicit selectors).
    @objc(mouseMoved:) func mouseMoved(with event: NSEvent) {
        guard let field else { return }
        pointerMoved(to: field.convert(event.locationInWindow, from: nil))
    }

    @objc(mouseEntered:) func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }
    @objc(mouseExited:) func mouseExited(with event: NSEvent) { hide() }

    func removeClicked() {
        guard let hovered else { return }
        hide()
        hovered.onRemove(hovered.attachmentID)
    }
}

/// The remove button: the xmark symbol, pressed by a click or by accessibility.
final class ComposeInlineRemoveButton: NSImageView {
    var onPress: () -> Void = {}

    init() {
        super.init(frame: .zero)
        image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: CmuxStrings.removeAttachment)
        contentTintColor = NSColor(white: 1, alpha: 0.95)
        imageScaling = .scaleProportionallyUpOrDown
        toolTip = CmuxStrings.removeAttachment
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(CmuxStrings.removeAttachment)
    }

    required init?(coder: NSCoder) { nil }

    override func mouseDown(with event: NSEvent) { onPress() }
    override func accessibilityPerformPress() -> Bool {
        onPress()
        return true
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }
}
