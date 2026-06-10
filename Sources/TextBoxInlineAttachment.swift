import AppKit
import Carbon.HIToolbox
import SwiftUI
import UniformTypeIdentifiers
import os


// MARK: - Inline Attachment Rendering
final class TextBoxInlineTextAttachment: NSTextAttachment {
    let textBoxAttachment: TextBoxAttachment

    init(
        attachment: TextBoxAttachment,
        font: NSFont,
        foregroundColor: NSColor
    ) {
        self.textBoxAttachment = attachment
        super.init(data: nil, ofType: nil)
        refreshCell(font: font, foregroundColor: foregroundColor)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func refreshCell(font: NSFont, foregroundColor: NSColor) {
        refreshCell(font: font, foregroundColor: foregroundColor, isFocused: false)
    }

    func refreshCell(font: NSFont, foregroundColor: NSColor, isFocused: Bool) {
        attachmentCell = TextBoxInlineAttachmentCell(
            attachment: textBoxAttachment,
            image: TextBoxInlineAttachmentRenderer.image(
                for: textBoxAttachment,
                font: font,
                foregroundColor: foregroundColor,
                isFocused: isFocused
            )
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

private final class TextBoxInlineAttachmentCell: NSTextAttachmentCell {
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
        return NSRect(
            x: position.x,
            y: lineFrag.minY,
            width: renderedImage.size.width,
            height: lineFrag.height
        )
    }

    private func drawnFrame(for cellFrame: NSRect) -> NSRect {
        NSRect(
            x: cellFrame.minX,
            y: cellFrame.midY - renderedImage.size.height / 2 + TextBoxLayout.inlineAttachmentVerticalOffset,
            width: renderedImage.size.width,
            height: renderedImage.size.height
        )
    }
}

private enum TextBoxInlineAttachmentRenderer {
    static func image(
        for attachment: TextBoxAttachment,
        font: NSFont,
        foregroundColor: NSColor,
        isFocused: Bool
    ) -> NSImage {
        let textFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingMiddle
        let textAttributes: [NSAttributedString.Key: Any] = [
            .font: textFont,
            .foregroundColor: foregroundColor.withAlphaComponent(0.90),
            .paragraphStyle: paragraph
        ]
        let textWidth = min(
            TextBoxLayout.inlineAttachmentMaxTextWidth,
            ceil((attachment.displayName as NSString).size(withAttributes: textAttributes).width)
        )
        let height = TextBoxLayout.attachmentChipHeight
        let iconSize = TextBoxLayout.attachmentImageSize
        let horizontalPadding: CGFloat = 6
        let iconTextGap: CGFloat = 4
        let width = horizontalPadding * 2
            + iconSize
            + iconTextGap
            + textWidth
            + TextBoxLayout.inlineAttachmentTrailingControlWidth

        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()
        defer { image.unlockFocus() }

        NSGraphicsContext.current?.imageInterpolation = .high
        let bounds = NSRect(origin: .zero, size: image.size)
        let background = foregroundColor.withAlphaComponent(isFocused ? 0.16 : 0.10)
        background.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: height / 2, yRadius: height / 2).fill()

        let border = isFocused
            ? NSColor.controlAccentColor.withAlphaComponent(0.95)
            : foregroundColor.withAlphaComponent(0.14)
        border.setStroke()
        let borderPath = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: height / 2, yRadius: height / 2)
        borderPath.lineWidth = isFocused ? 1.5 : 1
        borderPath.stroke()

        let iconRect = NSRect(
            x: horizontalPadding,
            y: (height - iconSize) / 2,
            width: iconSize,
            height: iconSize
        )
        if let thumbnail = attachment.thumbnail {
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: iconRect, xRadius: 4, yRadius: 4).addClip()
            thumbnail.draw(in: iconRect)
            NSGraphicsContext.restoreGraphicsState()
        } else {
            let icon = NSImage(systemSymbolName: "doc", accessibilityDescription: nil)
            icon?.withSymbolConfiguration(.init(pointSize: 11, weight: .medium))?
                .draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 0.9)
        }

        let textSize = (attachment.displayName as NSString).size(withAttributes: textAttributes)

        let textRect = NSRect(
            x: iconRect.maxX + iconTextGap,
            y: (height - textSize.height) / 2,
            width: textWidth,
            height: textSize.height
        )
        (attachment.displayName as NSString).draw(in: textRect, withAttributes: textAttributes)

        let closeAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9, weight: .bold),
            .foregroundColor: foregroundColor.withAlphaComponent(0.48)
        ]
        let closeString = "×" as NSString
        let closeSize = closeString.size(withAttributes: closeAttributes)
        closeString.draw(
            at: NSPoint(
                x: bounds.maxX - horizontalPadding - closeSize.width + 1,
                y: (height - closeSize.height) / 2
            ),
            withAttributes: closeAttributes
        )

        image.isTemplate = false
        return image
    }
}

