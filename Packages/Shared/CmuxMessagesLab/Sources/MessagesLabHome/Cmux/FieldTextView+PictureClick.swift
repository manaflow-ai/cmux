// cmux: a click on a picture in the message box opens it large (issue 51939). Not a vendored file.
import AppKit

extension FieldTextView {
    /// The picture under `point` (field coordinates), with its box: the field is TextKit 1 (ComposeTextView), which
    /// draws an attachment itself and never places ``ComposeInlineAttachmentView``, so the field finds the picture
    /// from its glyph boxes as the hover remove button does (``ComposeInlineRemoveHover``). File pills are left out.
    func picture(at point: CGPoint) -> (attachment: ComposeInlineAttachment, rect: CGRect)? {
        ComposeInlineRemoveHover.attachmentRects(in: self).first { $0.attachment.isImage && $0.rect.contains(point) }
    }

    /// After the field tracked a press: a single click that began and ended on the same picture (within
    /// ``ComposeInlineAttachmentView/clickSlop``, so a drag or a selection does not count) opens it large.
    @discardableResult
    func openPictureClicked(down: NSEvent, up: NSEvent) -> Bool {
        guard down.clickCount == 1, !down.modifierFlags.contains(.shift), !down.modifierFlags.contains(.command),
              ComposeInlineAttachmentView.isClick(from: down.locationInWindow, to: up.locationInWindow) else { return false }
        let point = convert(up.locationInWindow, from: nil)
        guard let hit = picture(at: point), hit.rect.contains(convert(down.locationInWindow, from: nil)) else { return false }
        return onOpenDraftPicture(hit.attachment.attachmentID, hit.rect, hit.attachment.thumbnail)
    }
}
