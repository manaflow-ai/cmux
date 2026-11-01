import AppKit
import CmuxNextDesign
import CmuxNextIcons

/// The "Done (N)", "Archived (N)" and "Show N more" rows at the end of a list (`SidebarLayout+DoneFold`): a chevron and the count in
/// the folder header's quiet style. A click opens or folds the rows it holds; it is no drop target and has no menu of
/// its own (its list's menu shows).
final class SidebarDoneFoldRowView: SidebarRowView {
    var isKeyboardFocused = false {
        didSet {
            performWithTheme {
                layer?.borderColor = Palette.focusRing.cgColor
                layer?.borderWidth = isKeyboardFocused ? Metrics.dividerThickness * 1.5 : 0
            }
            needsDisplay = true
        }
    }
    private let chevron = DecorativeImageView()
    private let name = SidebarRowView.label(font: SidebarStyle.headerFont)
    var onToggle: (() -> Bool)?
    /// SCRATCH mockup (`sidebar.archiveLayout`): the row's archive mock, nil for a real fold row.
    private var mock: SidebarArchiveMockRow?
    /// SCRATCH mockup: the count after "Archive", the trailing chevron and the switch / chips drawing.
    private let mockCount = SidebarRowView.label(font: SidebarStyle.headerFont)
    private let mockTrail = DecorativeImageView()
    private let drawing = SidebarArchiveMockDrawing()

    required init(key: SidebarRowKey) {
        super.init(key: key)
        addSubview(chevron)
        addSubview(name)
        [mockCount, mockTrail, drawing].forEach(addSubview)
        mockCount.isHidden = true
        mockTrail.isHidden = true
        drawing.isHidden = true
    }

    func configure(_ row: SidebarRow) {
        mock = row.archiveMock
        drawing.mock = row.archiveMock
        if let mock = row.archiveMock {
            configureMock(mock)
            return
        }
        name.isHidden = false
        chevron.isHidden = false
        mockCount.isHidden = true
        mockTrail.isHidden = true
        drawing.isHidden = true
        switch row.key {
        case .showMore:
            name.setString(row.isCollapsed ? Strings.showMore(row.childCount) : Strings.showFewer)
        case let .doneFold(fold) where fold.kind == .archived:
            name.setString(Strings.archivedFold(row.childCount))
        default:
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

    /// SCRATCH mockup (`sidebar.archiveLayout`): one of the archive layouts' rows. English only, never shipped.
    private func configureMock(_ mock: SidebarArchiveMockRow) {
        let trailSize = CGFloat.iconRowSize(forLabelPointSize: Metrics.smallIconSize - Metrics.space2)
        drawing.isHidden = true
        name.isHidden = false
        chevron.isHidden = false
        mockCount.isHidden = true
        mockTrail.isHidden = true
        mockCount.setFont(SidebarStyle.headerFont)
        let box = NSImage.icon(symbol: "archivebox", size: Metrics.smallIconSize - Metrics.space1)
        switch mock.kind {
        case let .section(open):
            name.setString("Archive")
            name.setFont(SidebarStyle.headerFont)
            chevron.image = box
            mockCount.setString("\(mock.count)")
            mockCount.isHidden = false
            mockTrail.isHidden = false
            mockTrail.image = NSImage.icon(open ? .disclosureExpanded : .disclosureCollapsed, size: trailSize)
        case .switcher, .chips:
            name.isHidden = true
            chevron.isHidden = true
            drawing.isHidden = false
            if case .chips = mock.kind {
                mockTrail.isHidden = false
                mockTrail.image = NSImage.icon(.disclosureCollapsed, size: trailSize)
            }
        case .footer:
            name.setString("\(mock.count) archived")
            name.setFont(Typography.caption)
            chevron.isHidden = true
            chevron.image = nil
        case .header:
            name.setString("Archive")
            name.setFont(NSFont.systemFont(ofSize: Typography.caption.pointSize, weight: .semibold))
            chevron.isHidden = true
            chevron.image = nil
            mockCount.setString("\(mock.count)")
            mockCount.setFont(Typography.caption)
            mockCount.isHidden = false
            mockTrail.isHidden = false
            mockTrail.image = NSImage.icon(.disclosureCollapsed, size: trailSize)
        case .showAll:
            name.setString("Show all \(mock.count) archived")
            name.setFont(SidebarStyle.headerFont)
            chevron.isHidden = true
            chevron.image = nil
        }
        setAccessibilityElement(true)
        setAccessibilityLabel("\(mock.count) archived")
        needsLayout = true
        needsDisplay = true
    }

    /// Whether the row draws its disclosure chevron (every fold row does; tests read it).
    var showsChevron: Bool { chevron.image != nil && !chevron.isHidden }

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
        mockCount.isHidden = true
        mockTrail.isHidden = true
    }

    override func layout() {
        super.layout()
        let b = layoutBounds
        let h = ceil(name.intrinsicContentSize.height)
        let icon = chevron.image?.size ?? .zero
        // The chevron starts where a row's title does, the count right after it.
        let start = SidebarStyle.titleLeading - SidebarStyle.labelCellPadding
        chevron.frame = NSRect(x: start, y: (b.height - icon.height) / 2, width: icon.width, height: icon.height)
        let x = chevron.frame.maxX + Metrics.space1
        name.frame = NSRect(x: x, y: (b.height - h) / 2, width: max(0, b.width - x - Metrics.space2), height: h)
        if let mock { layoutMock(mock, bounds: b) }
        needsDisplay = true
    }

    /// SCRATCH mockup: places the mock's label, count and trailing chevron.
    private func layoutMock(_ mock: SidebarArchiveMockRow, bounds b: NSRect) {
        drawing.frame = b
        let trail = mockTrail.image?.size ?? .zero
        let column = SidebarStyle.trailingColumnFrame(rowWidth: b.width, centerY: b.height / 2, side: SidebarStyle.trailingSlotSide)
        mockTrail.frame = NSRect(x: column.midX - trail.width / 2, y: (b.height - trail.height) / 2, width: trail.width, height: trail.height)
        let h = ceil(name.intrinsicContentSize.height)
        let nameWidth = ceil(name.intrinsicContentSize.width)
        let start = SidebarStyle.titleLeading - SidebarStyle.labelCellPadding
        switch mock.kind {
        case .section:
            name.frame = NSRect(x: name.frame.minX, y: (b.height - h) / 2, width: nameWidth, height: h)
            let ch = ceil(mockCount.intrinsicContentSize.height)
            mockCount.frame = NSRect(x: name.frame.maxX + Metrics.space1, y: (b.height - ch) / 2,
                                     width: ceil(mockCount.intrinsicContentSize.width), height: ch)
        case .footer, .showAll:
            name.frame = NSRect(x: start, y: (b.height - h) / 2, width: max(0, b.width - start - Metrics.space2), height: h)
        case .header:
            name.frame = NSRect(x: start, y: (b.height - h) / 2, width: nameWidth, height: h)
            let cw = ceil(mockCount.intrinsicContentSize.width), ch = ceil(mockCount.intrinsicContentSize.height)
            mockCount.frame = NSRect(x: mockTrail.frame.minX - Metrics.space1 - cw, y: (b.height - ch) / 2, width: cw, height: ch)
        case .switcher, .chips:
            break
        }
    }

    override func updateLayer() {
        performWithTheme {
            layer?.borderColor = Palette.focusRing.cgColor
            layer?.borderWidth = isKeyboardFocused ? Metrics.dividerThickness * 1.5 : 0
            name.setColor(Palette.textSecondary)
            chevron.contentTintColor = Palette.textSecondary
            if let mock {
                switch mock.kind {
                case .footer, .header: name.setColor(Palette.textTertiary)
                default: break
                }
                mockCount.setColor(Palette.textTertiary)
                mockTrail.contentTintColor = Palette.textTertiary
                drawing.colors = SidebarArchiveMockDrawing.Colors(
                    primary: Palette.textPrimary, secondary: Palette.textSecondary, tertiary: Palette.textTertiary,
                    knob: Palette.selectionFill, track: Palette.hoverFill)
                drawing.needsDisplay = true
            }
        }
    }
}

/// SCRATCH mockup (`sidebar.archiveLayout`): draws D's "Active | Archive" switch and G's stacked group color chips in a
/// mock row. English only (not shipped).
final class SidebarArchiveMockDrawing: NSView {
    struct Colors {
        var primary: NSColor, secondary: NSColor, tertiary: NSColor, knob: NSColor, track: NSColor
    }

    var mock: SidebarArchiveMockRow? { didSet { needsDisplay = true } }
    var colors = Colors(primary: .labelColor, secondary: .secondaryLabelColor, tertiary: .tertiaryLabelColor,
                        knob: .selectedContentBackgroundColor, track: .quaternaryLabelColor)

    nonisolated override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let mock else { return }
        let b = bounds
        let font = SidebarStyle.headerFont
        func size(_ string: String, _ font: NSFont) -> NSSize { (string as NSString).size(withAttributes: [.font: font]) }
        func text(_ string: String, x: CGFloat, color: NSColor, font: NSFont = SidebarStyle.headerFont) -> CGFloat {
            let s = size(string, font)
            (string as NSString).draw(at: NSPoint(x: x, y: (b.height - s.height) / 2), withAttributes: [.font: font, .foregroundColor: color])
            return x + ceil(s.width)
        }
        switch mock.kind {
        case let .switcher(archiveSelected):
            let inset = SidebarStyle.titleLeading - Metrics.space2
            let h = min(b.height - 4, 22)
            let track = NSRect(x: inset, y: (b.height - h) / 2, width: b.width - 2 * inset, height: h)
            colors.track.setFill()
            NSBezierPath(roundedRect: track, xRadius: h / 2, yRadius: h / 2).fill()
            let half = (track.width - 4) / 2
            let knob = NSRect(x: track.minX + 2 + (archiveSelected ? half : 0), y: track.minY + 2, width: half, height: h - 4)
            colors.knob.setFill()
            NSBezierPath(roundedRect: knob, xRadius: (h - 4) / 2, yRadius: (h - 4) / 2).fill()
            let labels = ["Active", "Archive \(mock.count)"]
            for (i, label) in labels.enumerated() {
                let s = size(label, font)
                let cx = track.minX + 2 + half * CGFloat(i) + half / 2
                let selected = (i == 1) == archiveSelected
                _ = text(label, x: cx - s.width / 2, color: selected ? colors.primary : colors.secondary)
            }
        case .chips:
            let side: CGFloat = 12, step: CGFloat = 7
            var x = SidebarStyle.titleLeading
            for (i, color) in mock.colors.prefix(9).enumerated() {
                let r = NSRect(x: SidebarStyle.titleLeading + CGFloat(i) * step, y: (b.height - side) / 2, width: side, height: side)
                let fill = GroupTint.palette(color).headerChip(themed: false).fill.nsColor
                let circle = NSBezierPath(ovalIn: r)
                fill.setFill()
                circle.fill()
                colors.track.setStroke()
                circle.lineWidth = 1.5
                circle.stroke()
                x = r.maxX
            }
            let after = text("Archive", x: x + Metrics.space2, color: colors.secondary)
            _ = text("\(mock.colors.count) groups · \(mock.count)", x: after + Metrics.space2, color: colors.tertiary, font: Typography.caption)
        case .section, .footer, .header, .showAll:
            break
        }
    }
}
