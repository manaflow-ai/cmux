import AppKit
import CmuxNextDesign

/// Group by Status's header: the bucket's name and its row count in the quiet header style, at
/// regular weight (no bold in the sidebar). A click folds or unfolds a bucket that folds; Needs you
/// draws no chevron. No menu of its own, no drop target.
final class StatusHeaderRowView: SidebarRowView {
    private let name = SidebarRowView.label(font: StatusHeaderRowView.font)
    private let count = SidebarRowView.label(font: StatusHeaderRowView.font)
    private let chevron = NSImageView()

    private static var font: NSFont {
        Typography.system(.default, size: SidebarStyle.headerFont.pointSize, weight: .regular)
    }

    required init(key: SidebarRowKey) {
        super.init(key: key)
        addSubview(name)
        addSubview(count)
        addSubview(chevron)
    }

    func configure(_ row: SidebarRow) {
        guard case let .status(bucket) = row.key else { return }
        name.stringValue = Strings.statusBucket(bucket)
        count.stringValue = "\(row.childCount)"
        (name.font, count.font) = (Self.font, Self.font)
        chevron.isHidden = !bucket.collapses
        chevron.image = NSImage.icon(row.isCollapsed ? .disclosureCollapsed : .disclosureExpanded,
                                     size: .iconRowSize(forLabelPointSize: Metrics.smallIconSize - Metrics.space2))
        setAccessibilityElement(true)
        setAccessibilityRole(bucket.collapses ? .disclosureTriangle : .staticText)
        setAccessibilityLabel("\(name.stringValue), \(Strings.groupCount(row.childCount))")
        if bucket.collapses { setAccessibilityExpanded(!row.isCollapsed) }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let b = layoutBounds
        let x = SidebarStyle.titleLeading - SidebarStyle.labelCellPadding
        let h = ceil(name.intrinsicContentSize.height)
        let nameWidth = min(ceil(name.intrinsicContentSize.width), max(0, b.width - x - Metrics.space6))
        name.frame = NSRect(x: x, y: (b.height - h) / 2, width: nameWidth, height: h)
        let countWidth = ceil(count.intrinsicContentSize.width)
        count.frame = NSRect(x: name.frame.maxX + Metrics.space1, y: name.frame.minY, width: countWidth, height: h)
        let side = chevron.image?.size.width ?? 0
        chevron.frame = NSRect(x: b.maxX - Metrics.space2 - side, y: (b.height - side) / 2, width: side, height: side)
        needsDisplay = true
    }

    override func updateLayer() {
        performWithTheme {
            name.textColor = Palette.textSecondary
            count.textColor = Palette.textTertiary
            chevron.contentTintColor = Palette.textTertiary
        }
    }
}
