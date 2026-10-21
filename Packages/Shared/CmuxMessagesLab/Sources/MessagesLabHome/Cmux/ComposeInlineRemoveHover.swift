// cmux: the remove button an inline attachment shows on hover (Draft+InlineMarks.swift). Not a vendored file.
import AppKit

/// The remove button at the top right of the inline attachment under the pointer. TextKit 2 draws
/// the field's attachments itself and did not place `ComposeInlineAttachmentView` (with its own
/// hover button) in the field, so the field tracks the pointer over its attachments instead
/// (Austin 2026-10-20: hovering a pasted picture showed no remove button).
@MainActor final class ComposeInlineRemoveHover: NSObject {
    private weak var field: NSTextView?
    let button = NSButton()
    /// The attachment the button removes (under the pointer).
    private(set) weak var hovered: ComposeInlineAttachment?

    /// Adds the button and the pointer tracking to FIELD.
    func install(on field: NSTextView) {
        self.field = field
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: CmuxStrings.removeAttachment)
        button.contentTintColor = NSColor(white: 1, alpha: 0.95)
        button.imageScaling = .scaleProportionallyUpOrDown
        button.setAccessibilityLabel(CmuxStrings.removeAttachment)
        button.toolTip = CmuxStrings.removeAttachment
        button.target = self
        button.action = #selector(removeClicked)
        button.isHidden = true
        field.addSubview(button)
        field.addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                             owner: self))
        NotificationCenter.default.addObserver(self, selector: #selector(textChanged), name: NSText.didChangeNotification, object: field)
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
            // The attachment is the tallest thing on its line, so its box starts at the line's top.
            guard let s = segment else { return }
            out.append((a, CGRect(x: s.minX + origin.x, y: s.minY + origin.y, width: s.width, height: min(s.height, a.bounds.height))))
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

    @objc func mouseMoved(with event: NSEvent) {
        guard let field else { return }
        pointerMoved(to: field.convert(event.locationInWindow, from: nil))
    }

    @objc func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }
    @objc func mouseExited(with event: NSEvent) { hide() }

    /// An edit moved or took away the attachments: the button waits for the pointer to move again.
    @objc private func textChanged() { hide() }

    @objc func removeClicked() {
        guard let hovered else { return }
        hide()
        hovered.onRemove(hovered.attachmentID)
    }
}
