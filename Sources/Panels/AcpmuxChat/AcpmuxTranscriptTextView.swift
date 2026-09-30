import AppKit

/// A read-only, selectable TextKit 1 text view configured to match ``AcpmuxTextMeasurer``.
final class AcpmuxTranscriptTextView: NSTextView {
    init() {
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 100, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.widthTracksTextView = false
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
        super.init(frame: .zero, textContainer: container)
        isEditable = false
        isSelectable = true
        drawsBackground = false
        textContainerInset = .zero
        isVerticallyResizable = false
        isHorizontallyResizable = false
        isRichText = true
        linkTextAttributes = [.cursor: NSCursor.pointingHand, .underlineStyle: NSUnderlineStyle.single.rawValue]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
    }

    func apply(_ text: NSAttributedString, frame: CGRect) {
        self.frame = frame
        textContainer?.size = NSSize(width: frame.width, height: .greatestFiniteMagnitude)
        if textStorage?.isEqual(to: text) != true {
            textStorage?.setAttributedString(text)
        }
    }

    /// Draws a rounded box behind each fenced code block, spanning the container width.
    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let storage = textStorage, let layoutManager, let textContainer, storage.length > 0 else { return }
        storage.enumerateAttribute(.acpmuxCodeBlock, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard let color = value as? NSColor else { return }
            let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            var box = CGRect.null
            // Used rects cover only the glyphs, so the box does not depend on paragraph spacing.
            layoutManager.enumerateLineFragments(forGlyphRange: glyphs) { _, usedRect, _, _, _ in
                box = box.union(usedRect)
            }
            guard !box.isNull else { return }
            let inset = AcpmuxChatTextRenderer.codeInset
            box = CGRect(x: 0, y: box.minY - inset, width: textContainer.size.width, height: box.height + 2 * inset)
            color.setFill()
            NSBezierPath(roundedRect: box.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y), xRadius: 7, yRadius: 7).fill()
        }
    }

    // Row clicks that are not text selections go to the row (for example to toggle a group).
    override func mouseDown(with event: NSEvent) {
        if let row = superview as? AcpmuxTranscriptRowCellView, row.handlesToggle {
            row.mouseDown(with: event)
            return
        }
        super.mouseDown(with: event)
    }
}
