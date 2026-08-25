import AppKit

final class TextBoxInlineAttachmentCell: NSTextAttachmentCell {
    private let textBoxAttachment: TextBoxAttachment
    private let renderedImage: NSImage

    init(attachment: TextBoxAttachment, image: NSImage) {
        self.textBoxAttachment = attachment
        self.renderedImage = image
        super.init(imageCell: image)
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func wantsToTrackMouse() -> Bool {
        true
    }

    override var cellSize: NSSize {
        NSSize(width: renderedImage.size.width, height: 1)
    }

    func uses(image: NSImage) -> Bool {
        renderedImage === image
    }

    override func trackMouse(
        with event: NSEvent,
        in cellFrame: NSRect,
        of controlView: NSView?,
        atCharacterIndex charIndex: Int,
        untilMouseUp flag: Bool
    ) -> Bool {
        guard event.type == .leftMouseDown,
              let textView = controlView as? TextBoxInputTextView else {
            return false
        }

        let clickPoint = textView.convert(event.locationInWindow, from: nil)
        let drawnCellFrame = drawnFrame(for: cellFrame)
        let closeRect = NSRect(
            x: drawnCellFrame.maxX - TextBoxLayout.inlineAttachmentTrailingControlWidth - 6,
            y: drawnCellFrame.minY,
            width: TextBoxLayout.inlineAttachmentTrailingControlWidth + 6,
            height: drawnCellFrame.height
        )
        textView.handleInlineAttachmentCellClick(
            attachment: textBoxAttachment,
            characterIndex: charIndex,
            clickCount: event.clickCount,
            isCloseClick: closeRect.contains(clickPoint)
        )
        return true
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        renderedImage.draw(in: drawnFrame(for: cellFrame))
    }

    override func cellFrame(
        for textContainer: NSTextContainer,
        proposedLineFragment lineFrag: NSRect,
        glyphPosition position: NSPoint,
        characterIndex charIndex: Int
    ) -> NSRect {
        NSRect(
            x: position.x,
            y: lineFrag.minY,
            width: renderedImage.size.width,
            height: lineFrag.height
        )
    }

    private func drawnFrame(for cellFrame: NSRect) -> NSRect {
        NSRect(
            x: cellFrame.minX,
            y: cellFrame.midY - renderedImage.size.height / 2
                + TextBoxLayout.inlineAttachmentVerticalOffset,
            width: renderedImage.size.width,
            height: renderedImage.size.height
        )
    }
}
