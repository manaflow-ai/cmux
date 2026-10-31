import AppKit
import CmuxNextDesign
import CmuxNextIcons

/// The "Done (N)" and "Show N more" rows at the end of a list (`SidebarLayout+DoneFold`): a chevron and the count in
/// the folder header's quiet style. A click opens or folds the rows it holds; it is no drop target and has no menu of
/// its own (its list's menu shows).
final class SidebarDoneFoldRowView: SidebarRowView {
    private let chevron = DecorativeImageView()
    private let name = SidebarRowView.label(font: SidebarStyle.headerFont)
    var onToggle: (() -> Bool)?
    /// SCRATCH mockup (`sidebar.archivedLook`): the row's archived look, nil for a real Done fold.
    private var mock: SidebarArchiveMockRow?
    /// SCRATCH mockup: the pile, filter and tidy drawings.
    private let drawing = SidebarArchiveMockDrawing()
    /// SCRATCH mockup: the global Archived row's leading box glyph.
    private var boxGlyph = false

    required init(key: SidebarRowKey) {
        super.init(key: key)
        addSubview(chevron)
        addSubview(name)
        addSubview(drawing)
    }

    func configure(_ row: SidebarRow) {
        mock = row.archiveMock
        drawing.mock = row.archiveMock
        drawing.isHidden = row.archiveMock.map { $0.kind == .fold || $0.kind == .dots } ?? true
        boxGlyph = row.archiveMock?.kind == .fold && row.group == nil
        if let mock = row.archiveMock {
            name.isHidden = !drawing.isHidden
            switch mock.kind {
            case .fold:
                name.setString("Archived (\(mock.count))")
                name.setFont(SidebarStyle.headerFont)
                chevron.isHidden = false
                chevron.image = boxGlyph
                    ? NSImage.icon(symbol: "archivebox", size: Metrics.smallIconSize - Metrics.space1)
                    : NSImage.icon(.disclosureCollapsed, size: .iconRowSize(forLabelPointSize: Metrics.smallIconSize - Metrics.space2))
            case .dots:
                name.setString("··· \(mock.count) archived")
                name.setFont(Typography.caption)
                chevron.isHidden = true
            case .pile, .filter, .tidy:
                chevron.isHidden = true
            }
            setAccessibilityElement(true)
            setAccessibilityLabel("\(mock.count) archived")
            needsLayout = true
            needsDisplay = true
            return
        }
        name.isHidden = false
        chevron.isHidden = false
        if case .showMore = row.key {
            name.setString(row.isCollapsed ? Strings.showMore(row.childCount) : Strings.showFewer)
        } else {
            name.setString(Strings.doneFold(row.childCount))
        }
        name.setFont(SidebarStyle.headerFont)
        chevron.image = NSImage.icon(row.isCollapsed ? .disclosureCollapsed : .disclosureExpanded,
                                     size: .iconRowSize(forLabelPointSize: Metrics.smallIconSize - Metrics.space2))
        setAccessibilityElement(true)
        setAccessibilityRole(.disclosureTriangle)
        setAccessibilityLabel(name.stringValue)
        setAccessibilityExpanded(!row.isCollapsed)
        needsLayout = true
    }

    override func accessibilityPerformPress() -> Bool {
        guard !isHiddenOrHasHiddenAncestor else { return false }
        return onToggle?() ?? false
    }

    override func prepareForReuse(key: SidebarRowKey) {
        super.prepareForReuse(key: key)
        onToggle = nil
        mock = nil
        drawing.mock = nil
        drawing.isHidden = true
    }

    override func layout() {
        super.layout()
        let b = layoutBounds
        drawing.frame = b
        let h = ceil(name.intrinsicContentSize.height)
        let icon = chevron.image?.size ?? .zero
        // The chevron starts where a row's title does, the count right after it.
        let start = SidebarStyle.titleLeading - SidebarStyle.labelCellPadding
        chevron.frame = NSRect(x: start, y: (b.height - icon.height) / 2, width: icon.width, height: icon.height)
        let x = chevron.frame.maxX + Metrics.space1
        name.frame = NSRect(x: x, y: (b.height - h) / 2, width: max(0, b.width - x - Metrics.space2), height: h)
        needsDisplay = true
    }

    override func updateLayer() {
        performWithTheme {
            name.setColor(mock?.kind == .dots ? Palette.textTertiary : Palette.textSecondary)
            chevron.contentTintColor = Palette.textSecondary
            drawing.colors = SidebarArchiveMockDrawing.Colors(
                primary: Palette.textPrimary, secondary: Palette.textSecondary, tertiary: Palette.textTertiary,
                fill: Palette.selectionFill, chip: Palette.hoverFill, accent: Palette.accent)
            drawing.needsDisplay = true
        }
    }
}

/// SCRATCH mockup (`sidebar.archivedLook`): draws the pile (stacked initials), the Active / All filter and the
/// Tidy Up hint ("N idle · Archive") in a mock row. Text in the mockup is English only (not shipped).
final class SidebarArchiveMockDrawing: NSView {
    struct Colors {
        var primary: NSColor, secondary: NSColor, tertiary: NSColor, fill: NSColor, chip: NSColor, accent: NSColor
    }

    var mock: SidebarArchiveMockRow? { didSet { needsDisplay = true } }
    var colors = Colors(primary: .labelColor, secondary: .secondaryLabelColor, tertiary: .tertiaryLabelColor,
                        fill: .selectedContentBackgroundColor, chip: .quaternaryLabelColor, accent: .controlAccentColor)

    nonisolated override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let mock else { return }
        let b = bounds
        let font = SidebarStyle.headerFont
        let start = SidebarStyle.titleLeading
        func text(_ string: String, x: CGFloat, color: NSColor, font: NSFont = SidebarStyle.headerFont) -> CGFloat {
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            let size = (string as NSString).size(withAttributes: attrs)
            (string as NSString).draw(at: NSPoint(x: x, y: (b.height - size.height) / 2), withAttributes: attrs)
            return x + ceil(size.width)
        }
        switch mock.kind {
        case .pile:
            let side: CGFloat = 16, step: CGFloat = 10
            let initials = mock.titles.prefix(3).map { String($0.trimmingCharacters(in: .whitespaces).prefix(1)).uppercased() }
            var x = start
            let small = Typography.caption
            for (i, letter) in initials.enumerated() {
                let r = NSRect(x: start + CGFloat(i) * step, y: (b.height - side) / 2, width: side, height: side)
                let circle = NSBezierPath(ovalIn: r)
                colors.chip.setFill()
                circle.fill()
                colors.tertiary.setStroke()
                circle.lineWidth = 1
                circle.stroke()
                let attrs: [NSAttributedString.Key: Any] = [.font: small, .foregroundColor: colors.secondary]
                let size = (letter as NSString).size(withAttributes: attrs)
                (letter as NSString).draw(at: NSPoint(x: r.midX - size.width / 2, y: r.midY - size.height / 2), withAttributes: attrs)
                x = r.maxX
            }
            _ = text("\(mock.count) archived", x: x + Metrics.space2, color: colors.secondary)
        case .filter:
            let pad: CGFloat = 8, h: CGFloat = min(b.height - 4, 20)
            let attrs: [NSAttributedString.Key: Any] = [.font: font]
            let active = "Active", all = "All \(mock.count)"
            let wa = ceil((active as NSString).size(withAttributes: attrs).width) + 2 * pad
            let wb = ceil((all as NSString).size(withAttributes: attrs).width) + 2 * pad
            let track = NSRect(x: start - 4, y: (b.height - h) / 2, width: wa + wb + 4, height: h)
            colors.chip.setFill()
            NSBezierPath(roundedRect: track, xRadius: h / 2, yRadius: h / 2).fill()
            let knob = NSRect(x: track.minX + 2, y: track.minY + 2, width: wa, height: h - 4)
            colors.fill.setFill()
            NSBezierPath(roundedRect: knob, xRadius: (h - 4) / 2, yRadius: (h - 4) / 2).fill()
            _ = text(active, x: knob.minX + pad, color: colors.primary)
            _ = text(all, x: knob.maxX + pad, color: colors.secondary)
        case .tidy:
            let x = text("\(mock.count) idle", x: start, color: colors.secondary)
            let y = text("  ·  ", x: x, color: colors.tertiary)
            _ = text("Archive", x: y, color: colors.accent)
        case .fold, .dots:
            break
        }
    }
}
