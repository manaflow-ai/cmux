import AppKit
import CmuxNextDesign

/// The open conversation's title and participants above the transcript,
/// flat on the window background.
final class HomeHeaderView: NSView {
    var title = "" { didSet { if title != oldValue { needsDisplay = true } } }
    var subtitle = "" { didSet { if subtitle != oldValue { needsDisplay = true } } }

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    required init?(coder: NSCoder) { nil }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        if changed { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        performWithTheme {
            Palette.paneFill.setFill()
            bounds.fill()
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            paragraph.lineBreakMode = .byTruncatingTail
            let titleFont = Typography.bodyEmphasized
            let subtitleFont = Typography.caption
            let titleHeight = ceil(titleFont.pointSize * 1.3)
            let subtitleHeight = subtitle.isEmpty ? 0 : ceil(subtitleFont.pointSize * 1.3)
            let top = (bounds.height - titleHeight - subtitleHeight) / 2
            let inset = Metrics.space6
            (title as NSString).draw(in: CGRect(x: inset, y: top, width: bounds.width - 2 * inset, height: titleHeight),
                                     withAttributes: [.font: titleFont, .foregroundColor: Palette.textPrimary,
                                                      .paragraphStyle: paragraph])
            if !subtitle.isEmpty {
                (subtitle as NSString).draw(
                    in: CGRect(x: inset, y: top + titleHeight, width: bounds.width - 2 * inset, height: subtitleHeight),
                    withAttributes: [.font: subtitleFont, .foregroundColor: Palette.textSecondary, .paragraphStyle: paragraph])
            }
            Palette.separator.setFill()
            CGRect(x: 0, y: bounds.height - 1 / max(1, window?.backingScaleFactor ?? 2), width: bounds.width,
                   height: 1 / max(1, window?.backingScaleFactor ?? 2)).fill()
        }
    }
}
