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
        let x = SidebarStyle.columns(rowWidth: b.width).lead - SidebarStyle.labelCellPadding
        let h = ceil(name.intrinsicContentSize.height)
        let side = Metrics.smallIconSize
        // A label's frame holds its text and its padding on both sides (`naturalSize`); the
        // text alone (`intrinsicContentSize`) truncated "Running" to "Runn…" and clipped the
        // count. The count's text still starts `space1` after the name's text.
        let nameWidth = min(ceil(name.naturalSize.width), max(0, b.width - x - side - Metrics.space6))
        name.frame = NSRect(x: x, y: SidebarStyle.textY(name, centerY: b.midY), width: nameWidth, height: h)
        let namePadding = name.naturalSize.width - name.intrinsicContentSize.width
        count.frame = NSRect(x: name.frame.maxX - namePadding + Metrics.space1, y: name.frame.minY,
                             width: ceil(count.naturalSize.width), height: h)
        // On the trailing column every row's mark and the group header's chevron share (Leo 2026-10-28: "the alignment").
        chevron.frame = SidebarStyle.trailingColumnFrame(rowWidth: b.width, centerY: b.midY, side: side).offsetBy(dx: b.minX, dy: 0)
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
