import AppKit
import CmuxNextDesign

/// DEV and NIGHTLY (the Debug menu): the Folder Corners page. Leo 2026-11-12, of the title area's two looks: "a
/// goldilocks and high standard with all the trimmings properly looked at (e.g. the tabs at the top having the same
/// transparency, all corners looking good". Each row is a window's top-leading part on the default flush corner, drawn
/// from the app's own geometry (``CornerFlush``, ``CornerFlushChrome/wedgePath(card:radius:squareLeading:)``,
/// ``TabCell/feetPath(pill:radius:skipsLeading:)``): One Color, the default, first, then Subtle Tone with the
/// selected tab in the middle, first beside a left sidebar, first with the sidebar on the right, and fullscreen.
struct FolderCornerPlaygroundVariants {
    var all: [TabBarPlaygroundVariant] {
        FolderCornerPlaygroundRow.Look.allCases.map { look in
            TabBarPlaygroundVariant(name: look.name, isShipped: look == .oneColor) { _ in FolderCornerPlaygroundRow(look: look) }
        }
    }
}

/// One row of the Folder Corners page: a window corner, its sidebar, the tab row and the content card below it.
final class FolderCornerPlaygroundRow: NSView, TabBarPlaygroundRow {
    enum Look: CaseIterable {
        case oneColor
        case subtleMiddle
        case subtleFirstSidebarLeft
        case subtleFirstSidebarRight
        case subtleFullscreen

        var name: String {
            switch self {
            case .oneColor: Strings.playgroundFolderOneColor
            case .subtleMiddle: Strings.playgroundFolderMiddle
            case .subtleFirstSidebarLeft: Strings.playgroundFolderFirstLeft
            case .subtleFirstSidebarRight: Strings.playgroundFolderFirstRight
            case .subtleFullscreen: Strings.playgroundFolderFullscreen
            }
        }

        var toned: Bool { self != .oneColor }
        var selectsFirst: Bool { self == .subtleFirstSidebarLeft || self == .subtleFirstSidebarRight || self == .oneColor }
        var sidebarOnLeft: Bool { self != .subtleFirstSidebarRight }
    }

    static let preferredHeight: CGFloat = 150
    private static let tabCount = 4
    private static let sidebarWidth: CGFloat = 150

    private let look: Look
    private let frameLayer = CALayer()
    private let content = CALayer()
    private let pill = CALayer()
    private let shade = CAShapeLayer()
    private let divider = CAShapeLayer()
    private let edge = CALayer()
    private var titles: [CATextLayer] = []

    init(look: Look) {
        self.look = look
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: Self.preferredHeight))
        wantsLayer = true
        frameLayer.masksToBounds = true
        frameLayer.cornerCurve = .circular
        layer?.addSublayer(frameLayer)
        for sublayer in [content, pill, shade, divider, edge] { frameLayer.addSublayer(sublayer) }
        content.cornerCurve = .circular
        pill.cornerCurve = .circular
        for _ in 0..<Self.tabCount {
            let title = CATextLayer()
            title.font = Typography.caption
            title.fontSize = Typography.caption.pointSize
            title.alignmentMode = .center
            frameLayer.addSublayer(title)
            titles.append(title)
        }
        applyColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: Self.preferredHeight) }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    // Unflipped, as the window root: the top is maxY, which ``CornerFlushChrome/wedgePath(card:radius:squareLeading:)`` reads.
    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let flush = CornerFlush.goo
        let fullscreen = look == .subtleFullscreen
        // The window's top part: its bottom runs off the row, so only its top corners show.
        frameLayer.frame = CGRect(x: Metrics.space3, y: 0, width: bounds.width - 2 * Metrics.space3, height: bounds.height - Metrics.space3)
        frameLayer.cornerRadius = fullscreen ? 0 : Metrics.standardWindowCornerRadius
        frameLayer.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        let frame = frameLayer.bounds
        for title in titles { title.contentsScale = window?.backingScaleFactor ?? 2 }
        let gap = flush.gap
        let radius = fullscreen ? flush.cardRadius : max(0, Metrics.standardWindowCornerRadius - gap)
        // The content beside the sidebar, inset by the frame's gap; the tab row is its top strip.
        let side = Self.sidebarWidth
        let minX = look.sidebarOnLeft ? side + gap : gap
        let maxX = look.sidebarOnLeft ? frame.maxX - gap : frame.maxX - side - gap
        let stripHeight = PaneChromeMetrics.current.resolvedStripHeight(scale: window?.backingScaleFactor ?? 2)
        let whole = CGRect(x: minX, y: -radius, width: max(0, maxX - minX), height: frame.maxY - gap + radius)
        var card = whole
        card.size.height = max(0, whole.height - stripHeight)
        content.frame = whole
        content.cornerRadius = radius
        edge.frame = CGRect(x: look.sidebarOnLeft ? side : frame.maxX - side, y: 0, width: Metrics.dividerThickness, height: frame.height)

        // The tabs, from the content's leading edge (tabs never mirror with the sidebar).
        let tabHeight = Metrics.tabHeight
        let tabWidth: CGFloat = 120
        let pillY = card.maxY + (stripHeight - tabHeight) / 2
        let selected = look.selectsFirst ? 0 : 1
        var pills: [CGRect] = []
        for index in 0..<Self.tabCount {
            let rect = CGRect(x: minX + CGFloat(index) * tabWidth, y: pillY, width: tabWidth, height: tabHeight)
            pills.append(rect)
            titles[index].frame = CGRect(x: rect.minX, y: rect.midY - 8, width: rect.width, height: 16)
            titles[index].string = Strings.playgroundTabTitle(index + 1)
        }
        let chosen = pills[selected]
        let squareLeading = look.toned && selected == 0
        let tabRadius = min(Metrics.tabCornerRadius, tabHeight / 2)

        guard look.toned else {
            // One Color: no shade; the selected tab is a pill and the tab row's divider runs the whole width.
            shade.path = nil
            pill.isHidden = false
            pill.frame = chosen
            pill.cornerRadius = tabRadius
            divider.path = CGPath(rect: CGRect(x: card.minX, y: card.maxY, width: card.width, height: Metrics.dividerThickness), transform: nil)
            return
        }
        pill.isHidden = true
        // The folder: the pill down to the card, round on top only, with its fillets (none on a side on the card's edge).
        var body = chosen
        body.size.height += body.minY - card.maxY
        body.origin.y = card.maxY
        let feet = Self.unflipped(TabCell.feetPath(pill: Self.flipped(body, in: frame), radius: flush.feetRadius, skipsLeading: squareLeading),
                                  in: frame)
        let folder = CGPath(roundedRect: body, cornerWidth: tabRadius, cornerHeight: tabRadius, transform: nil)
            .union(CGPath(rect: CGRect(x: body.minX, y: body.minY, width: body.width, height: body.height - tabRadius), transform: nil))
            .union(feet)
        // The frame's shade: everything but the card (its top corners rounded by the wedges, the leading one squared
        // under a first tab) and the folder, which shows the content's own colour.
        var hole = CGPath(roundedRect: card, cornerWidth: radius, cornerHeight: radius, transform: nil)
        if squareLeading { hole = hole.union(CGPath(rect: CGRect(x: card.minX, y: card.maxY - radius, width: radius, height: radius), transform: nil)) }
        let wedges = CornerFlushChrome.wedgePath(card: card, radius: radius, squareLeading: squareLeading)
        shade.path = CGPath(rect: frame, transform: nil).subtracting(hole.union(folder)).union(wedges)
        let line = CGRect(x: card.minX + (squareLeading ? 0 : radius), y: card.maxY - Metrics.dividerThickness,
                          width: card.width - radius - (squareLeading ? 0 : radius), height: Metrics.dividerThickness)
        divider.path = CGPath(rect: line, transform: nil).subtracting(folder)
    }

    private func applyColors() {
        performWithTheme {
            frameLayer.backgroundColor = Palette.contentBackground.cgColor
            content.backgroundColor = Palette.contentBackground.cgColor
            pill.backgroundColor = Palette.selectionFill.cgColor
            let isDark = themeTokens.isDark
            shade.fillColor = NSColor.black.withAlphaComponent(CornerFlush.goo.shade(isDark: isDark) * TitleAreaTone.subtleShare).cgColor
            divider.fillColor = Palette.chromeDivider.cgColor
            edge.backgroundColor = Palette.chromeDivider.cgColor
            for title in titles { title.foregroundColor = Palette.textSecondary.cgColor }
        }
        needsLayout = true
    }

    /// `rect` in a flipped space of `frame`'s height (``TabCell/feetPath(pill:radius:skipsLeading:)`` reads maxY as the card's top).
    private static func flipped(_ rect: CGRect, in frame: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: frame.height - rect.maxY, width: rect.width, height: rect.height)
    }

    private static func unflipped(_ path: CGPath, in frame: CGRect) -> CGPath {
        var flip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: frame.height)
        return path.copy(using: &flip) ?? path
    }
}
