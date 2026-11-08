import AppKit
import CmuxNextDesign

/// DEV and NIGHTLY (Debug menu > Sidebar States Playground): one cell of a sheet: the real row's pixels at their
/// point size, the leading-inset and trailing-column guides over them, and under them each trailing mark's measured
/// size (frame / ink, in points), leading to trailing.
final class SidebarStatesPlaygroundCellView: NSView {
    /// The caption line's height under the row.
    static var captionHeight: CGFloat { ceil(Typography.caption.boundingRectForFont.height) + Metrics.space1 }

    let cell: SidebarStatesPlaygroundCell
    private let image: NSImage?
    private let caption = NSTextField(labelWithString: "")

    init(cell: SidebarStatesPlaygroundCell) {
        self.cell = cell
        image = cell.image.map { NSImage(cgImage: $0, size: cell.size) }
        super.init(frame: NSRect(origin: .zero, size: Self.size(cell)))
        caption.font = Typography.caption
        caption.textColor = .secondaryLabelColor
        caption.lineBreakMode = .byTruncatingTail
        caption.stringValue = cell.image == nil ? Strings.statesPlaygroundNotDrawn
            : ([cell.card?.sizeText(rowHeight: cell.rowFrame.height)].compactMap { $0 } + cell.bars.map(\.sizeText)
                + cell.marks.map(\.sizeText)).joined(separator: "   ")
        addSubview(caption)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The cell's size: the row's, then the caption line.
    static func size(_ cell: SidebarStatesPlaygroundCell) -> NSSize {
        NSSize(width: cell.size.width, height: cell.size.height + captionHeight)
    }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        caption.frame = NSRect(x: 0, y: cell.size.height, width: bounds.width, height: Self.captionHeight)
    }

    override func draw(_ dirtyRect: NSRect) {
        let rowRect = NSRect(origin: .zero, size: cell.size)
        NSColor.separatorColor.setFill()
        rowRect.fill()
        image?.draw(in: rowRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        // One device pixel wide, so a guide never hides the mark it runs through.
        let line = 1 / max(window?.backingScaleFactor ?? cell.scale, 1)
        for (x, color) in [(cell.leadingGuideX, NSColor.systemTeal), (cell.columnGuideX, NSColor.systemPink)] {
            guard let x, cell.image != nil else { continue }
            color.withAlphaComponent(0.7).setFill()
            NSRect(x: x - line / 2, y: 0, width: line, height: cell.size.height).fill()
        }
    }
}
