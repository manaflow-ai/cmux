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

    // Row clicks that are not text selections go to the row (for example to toggle a group).
    override func mouseDown(with event: NSEvent) {
        if let row = superview as? AcpmuxTranscriptRowCellView, row.handlesToggle {
            row.mouseDown(with: event)
            return
        }
        super.mouseDown(with: event)
    }
}
