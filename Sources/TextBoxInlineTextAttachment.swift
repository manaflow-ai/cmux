import AppKit

final class TextBoxInlineTextAttachment: NSTextAttachment {
    let textBoxAttachment: TextBoxAttachment
    private(set) var isFocused = false

    @MainActor
    init(
        attachment: TextBoxAttachment,
        font: NSFont,
        foregroundColor: NSColor,
        renderer: TextBoxInlineAttachmentRenderer,
        appearance: NSAppearance,
        backingScale: CGFloat
    ) {
        self.textBoxAttachment = attachment
        super.init(data: nil, ofType: nil)
        refreshCell(
            font: font,
            foregroundColor: foregroundColor,
            isFocused: false,
            renderer: renderer,
            appearance: appearance,
            backingScale: backingScale
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @MainActor
    func refreshCell(
        font: NSFont,
        foregroundColor: NSColor,
        isFocused: Bool,
        renderer: TextBoxInlineAttachmentRenderer,
        appearance: NSAppearance,
        backingScale: CGFloat
    ) {
        self.isFocused = isFocused
        let image = renderer.image(
            for: textBoxAttachment,
            font: font,
            foregroundColor: foregroundColor,
            isFocused: isFocused,
            appearance: appearance,
            backingScale: backingScale
        )
        if let existingCell = attachmentCell as? TextBoxInlineAttachmentCell,
           existingCell.uses(image: image) {
            return
        }
        attachmentCell = TextBoxInlineAttachmentCell(
            attachment: textBoxAttachment,
            image: image
        )
    }

    override func attachmentBounds(
        for textContainer: NSTextContainer?,
        proposedLineFragment lineFrag: NSRect,
        glyphPosition position: NSPoint,
        characterIndex charIndex: Int
    ) -> NSRect {
        let width = attachmentCell?.cellSize().width ?? 1
        return NSRect(x: 0, y: 0, width: width, height: 1)
    }
}
