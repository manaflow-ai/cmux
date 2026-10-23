import AppKit
import CmuxNextDesign

/// Group by Status's header (`SidebarRowKey.status`): the section's name in the Priority view's words and its row
/// count, in the group header's quiet style. A click folds or unfolds a section that folds; Needs you draws no
/// chevron. No menu of its own, no drop target.
final class StatusHeaderRowView: SidebarRowView {
    private let name = SidebarRowView.label(font: SidebarStyle.headerFont)
    private let count = SidebarRowView.label(font: SidebarStyle.headerFont)
    private let chevron = NSImageView()

    required init(key: SidebarRowKey) {
        super.init(key: key)
        chevron.setAccessibilityElement(false)
        addSubview(name)
        addSubview(count)
        addSubview(chevron)
    }

    func configure(_ row: SidebarRow) {
        guard case let .status(section) = row.key else { return }
        name.setString(Strings.statusSection(section))
        count.setString("\(row.childCount)")
        name.setFont(SidebarStyle.headerFont)
        count.setFont(SidebarStyle.headerFont)
        chevron.isHidden = !section.collapses
        chevron.image = SidebarStyle.chevron(collapsed: row.isCollapsed)
        setAccessibilityElement(true)
        setAccessibilityRole(section.collapses ? .disclosureTriangle : .staticText)
        setAccessibilityLabel("\(name.stringValue), \(Strings.groupCount(row.childCount))")
        if section.collapses { setAccessibilityExpanded(!row.isCollapsed) }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let b = layoutBounds
        let x = SidebarStyle.titleLeading - SidebarStyle.labelCellPadding
        let h = ceil(name.intrinsicContentSize.height)
        let side = Metrics.smallIconSize
        let nameWidth = min(ceil(name.intrinsicContentSize.width), max(0, b.width - x - side - Metrics.space6))
        name.frame = NSRect(x: x, y: (b.height - h) / 2, width: nameWidth, height: h)
        count.frame = NSRect(x: name.frame.maxX + Metrics.space1, y: name.frame.minY, width: ceil(count.intrinsicContentSize.width), height: h)
        chevron.frame = NSRect(x: b.maxX - Metrics.space2 - side, y: (b.height - side) / 2, width: side, height: side)
        needsDisplay = true
    }

    override func updateLayer() {
        performWithTheme {
            name.setColor(Palette.textSecondary)
            count.setColor(Palette.textTertiary)
            chevron.contentTintColor = Palette.textTertiary
        }
    }
}
