import AppKit
import CmuxNextDesign

/// DEV and NIGHTLY (the Debug menu): one row of the Corner Radius page (Lawrence 2026-11-04: one
/// radius for tabs and panes, every nested corner concentric, inner = outer minus padding). A
/// pane card of radius `outer` holds the real ``TabStripView`` set `padding` points in from its
/// top and leading edges, with pills of the ``ConcentricCorners`` inner radius, and a content area
/// whose selection fill sits `padding` inside the card's bottom corners with the same inner radius.
/// The hover, click, close and + of the strip are live.
final class ConcentricCornerPlaygroundRow: NSView {
    /// The row's height: the card and the shade around it.
    static let preferredHeight: CGFloat = 132

    private let corners: ConcentricCorners
    private let strip: TabStripView
    private let card = CALayer()
    private let content = CALayer()
    private let selection = CALayer()
    private let shade = CALayer()
    private let caption = NSTextField(labelWithString: "")

    /// - Parameters:
    ///   - corners: the outer radius and padding the row shows.
    ///   - strip: the real strip, its metrics set by the caller from `corners`.
    init(corners: ConcentricCorners, strip: TabStripView) {
        self.corners = corners
        self.strip = strip
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: Self.preferredHeight))
        wantsLayer = true
        strip.dragsWindowFromEmptySpace = false
        for sublayer in [shade, card, content, selection] {
            sublayer.cornerCurve = .circular
            layer?.addSublayer(sublayer)
        }
        addSubview(strip)
        caption.font = Typography.caption
        caption.textColor = Palette.textSecondary
        caption.stringValue = Strings.playgroundCornerCaption(inner: corners.inner)
        addSubview(caption)
        applyColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: Self.preferredHeight) }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let gutter = Metrics.space3
        shade.frame = bounds
        let cardRect = bounds.insetBy(dx: gutter, dy: gutter)
        card.frame = cardRect
        card.cornerRadius = corners.radius(fitting: cardRect.size, radius: corners.outer)
        let padding = corners.padding
        let tabHeight = strip.metrics.tabHeight
        // The strip's pills sit `padding` in from the card's top and leading edges (equal gap above and below).
        let stripRect = CGRect(x: cardRect.minX + padding, y: cardRect.minY, width: max(0, cardRect.width * 0.6 - padding),
                               height: tabHeight + 2 * padding)
        strip.frame = stripRect
        let body = CGRect(x: cardRect.minX, y: stripRect.maxY, width: cardRect.width, height: max(0, cardRect.maxY - stripRect.maxY))
        content.frame = body
        content.cornerRadius = card.cornerRadius
        content.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        // A selection fill nested `padding` inside the card's bottom-leading corner: the inner radius.
        let fill = CGRect(x: body.minX + padding, y: body.maxY - padding - 22, width: min(260, body.width / 2), height: 22)
        selection.frame = fill
        selection.cornerRadius = corners.radius(fitting: fill.size, radius: corners.nested(in: card.cornerRadius, inset: padding))
        caption.sizeToFit()
        caption.frame.origin = CGPoint(x: cardRect.minX + cardRect.width * 0.6 + Metrics.space4,
                                       y: cardRect.minY + (stripRect.height - caption.frame.height) / 2)
    }

    private func applyColors() {
        performWithTheme {
            // The chrome around the card, shaded so the card's outer corner reads (as `MainPaneChromeShadeView`).
            shade.backgroundColor = (Palette.windowBackground.blended(withFraction: 0.35, of: .black) ?? Palette.windowBackground).cgColor
            card.backgroundColor = Palette.stripBackground.cgColor
            content.backgroundColor = Palette.contentBackground.cgColor
            selection.backgroundColor = Palette.selectionFill.cgColor
        }
    }
}
