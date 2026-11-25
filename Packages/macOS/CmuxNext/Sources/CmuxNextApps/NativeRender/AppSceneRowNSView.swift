import AppKit
import CmuxNextDesign
import CmuxNextIcons
import QuartzCore

/// `Row`: the sidebar's own row, drawn as a pinned or workspace row draws (``AppSceneRowMetrics``):
/// a fill inset from the section's edges with the rows' corner, the leading glyph in the icon column,
/// the title in the rows' title font and primary ink, an optional detail line, and a trailing badge,
/// unread dot or accessory. The fill follows the shared chrome states (`ChromeHover`): hover and press
/// for a row with an `onTap` handler, the selection fill for a `selected` row, fading on pointer
/// changes. Hover and press stay local (no round trip to the script); a click sends `tap`.
final class AppSceneRowNSView: AppSceneNodeNSView {
    let pill = CALayer()
    let icon = NSImageView()
    let title = ChromeLabel(labelWithString: "")
    let subtitle = ChromeLabel(labelWithString: "")
    let badge = AppSceneBadgeLabel()
    let accessory = NSImageView()
    let unreadDot = CALayer()
    private var pointerHover: PointerHover?
    private var isHovered = false
    private var isPressed = false
    private var fadesNextFill = false
    /// The detail line's height for the last caption font (one TextKit measure per font change).
    private var detailLine: (font: NSFont, height: CGFloat)?

    override init(id: String, node: AppSceneNode) {
        super.init(id: id, node: node)
        for decoration in [pill, unreadDot] {
            decoration.actions = ["backgroundColor": NSNull(), "bounds": NSNull(), "position": NSNull()]
            decoration.cornerCurve = .continuous
            layer?.addSublayer(decoration)
        }
        icon.imageScaling = .scaleProportionallyDown
        accessory.imageScaling = .scaleProportionallyDown
        for label in [title, subtitle] {
            label.lineBreakMode = .byTruncatingTail
            label.maximumNumberOfLines = 1
        }
        [icon, title, subtitle, badge, accessory].forEach(addSubview)
        setAccessibilityElement(true)
        focusRingType = .none
        pointerHover = PointerHover(self) { [weak self] hovering in self?.hoverChanged(hovering) }
    }

    override func configure(_ node: AppSceneNode) {
        let selectionChanged = node.flag("selected") != self.node.flag("selected")
        super.configure(node)
        if selectionChanged { fadesNextFill = false }
        let metrics = AppSceneRowMetrics.current
        title.stringValue = node.string("title") ?? ""
        title.font = metrics.titleFont(emphasized: node.flag("unread"))
        let detail = node.string("subtitle").flatMap { $0.isEmpty ? nil : $0 }
        subtitle.stringValue = detail ?? ""
        subtitle.isHidden = detail == nil
        subtitle.font = metrics.captionFont
        icon.image = node.string("symbol").map { NSImage.icon(symbol: $0, size: metrics.glyphSide) }
        icon.isHidden = icon.image == nil
        accessory.image = node.string("accessory").map { NSImage.icon(symbol: $0, size: Metrics.smallIconSize) }
        accessory.isHidden = accessory.image == nil
        badge.configure(text: node.string("badge"), tone: node.props["tint"])
        setAccessibilityRole(isTappable ? .button : .staticText)
        setAccessibilityLabel(title.stringValue)
        setAccessibilityValue(detail)
        setAccessibilitySelected(node.flag("selected"))
        performWithTheme { paintContent() }
    }

    private var hasDetail: Bool { !subtitle.isHidden }

    private func detailLineHeight(_ metrics: AppSceneRowMetrics) -> CGFloat {
        let font = metrics.captionFont
        if let detailLine, detailLine.font == font { return detailLine.height }
        let height = ceil(NSLayoutManager().defaultLineHeight(for: font))
        detailLine = (font, height)
        return height
    }

    override func contentHeight(width: CGFloat) -> CGFloat {
        let metrics = AppSceneRowMetrics.current
        return metrics.rowHeight(detailLineHeight: hasDetail ? detailLineHeight(metrics) : nil)
    }

    override func layoutContent(in rect: CGRect) {
        let metrics = AppSceneRowMetrics.current
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pill.frame = CGRect(x: rect.minX + metrics.inset, y: rect.minY, width: max(0, rect.width - 2 * metrics.inset), height: rect.height)
        pill.cornerRadius = metrics.cornerRadius
        let midY = rect.midY
        let lead = rect.minX + 2 * metrics.inset
        // The glyph's box starts on the icon column's leading edge, as a workspace row's icon ink does.
        let glyph = metrics.glyphSide
        icon.frame = CGRect(x: lead + (metrics.iconColumn - glyph) / 2, y: midY - glyph / 2, width: glyph, height: glyph).integral

        // Trailing marks, right to left: the accessory, then the badge or the unread dot.
        var trailing = rect.minX + metrics.trailingX(width: rect.width)
        if !accessory.isHidden {
            let side = Metrics.smallIconSize
            accessory.frame = CGRect(x: trailing - side, y: midY - side / 2, width: side, height: side).integral
            trailing -= side + Metrics.space2
        }
        let dot = Metrics.space4
        let showsDot = badge.isHidden && node.flag("unread")
        unreadDot.isHidden = !showsDot
        if !badge.isHidden {
            let size = badge.fittingSize
            badge.frame = CGRect(x: trailing - size.width, y: midY - size.height / 2, width: size.width, height: size.height).integral
            trailing -= size.width + Metrics.space2
        } else if showsDot {
            unreadDot.frame = CGRect(x: trailing - dot, y: midY - dot / 2, width: dot, height: dot)
            unreadDot.cornerRadius = dot / 2
            trailing -= dot + Metrics.space2
        }
        CATransaction.commit()

        // The label's 2 pt line fragment padding sits left of the text column, so the ink starts on it.
        let textX = rect.minX + metrics.textX(hasIcon: !icon.isHidden) - Self.labelInset
        let textWidth = max(0, trailing - textX)
        let titleHeight = ceil(title.naturalSize.height)
        if hasDetail {
            let detailHeight = ceil(subtitle.naturalSize.height)
            let top = midY - (titleHeight + detailLineHeight(metrics)) / 2
            title.frame = CGRect(x: textX, y: top, width: textWidth, height: titleHeight).integral
            subtitle.frame = CGRect(x: textX, y: top + titleHeight, width: textWidth, height: detailHeight).integral
        } else {
            title.frame = CGRect(x: textX, y: midY - titleHeight / 2, width: textWidth, height: titleHeight).integral
        }
    }

    /// A chrome label's line fragment padding: its frame starts this far left of its first glyph.
    static let labelInset: CGFloat = 2

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { performWithTheme { paintContent() } }
    }

    override func paint() {
        performWithTheme {
            let state = ChromeHover.State(hovering: isHovered && isTappable, pressed: isPressed, selected: node.flag("selected"))
            ChromeHover.paint(pill, ChromeHover.fillColor(state), animated: fadesNextFill && window != nil)
            fadesNextFill = false
            paintContent()
        }
    }

    /// The text, icon and badge colors from the theme in scope: on each configure (so a row reads
    /// right before its first draw) and on each draw (appearance and theme changes).
    private func paintContent() {
        title.textColor = Palette.textPrimary
        subtitle.textColor = Palette.textSecondary
        let tint = node.props["tint"]?.sceneColor ?? (node.flag("selected") ? Palette.textPrimary : Palette.textSecondary)
        icon.contentTintColor = tint
        accessory.contentTintColor = Palette.textTertiary
        unreadDot.backgroundColor = Palette.textPrimary.cgColor
        badge.applyColors()
    }

    private func hoverChanged(_ hovering: Bool) {
        guard hovering != isHovered else { return }
        isHovered = hovering
        if !hovering { isPressed = false }
        fadesNextFill = true
        needsDisplay = true
    }

    override func pressChanged(_ pressed: Bool) {
        isPressed = pressed
        fadesNextFill = true
        needsDisplay = true
    }
}
