import AppKit
import CmuxNextDesign

/// The Needs you section's header (`SidebarRowKey.needsYou(.header)`, Leo 2026-11-10): "Needs you" in the group header's
/// quiet style, with the fold chevron on the trailing column that every row's mark and a project header's chevron share.
/// Folded, it says how many rows it holds (the gallery's `sidebar.project-caps.needs-you`, pick `rows`). A click folds or
/// opens it, as a project's header does; no menu of its own, no drop target.
final class NeedsYouHeaderRowView: SidebarRowView {
    private let name = SidebarRowView.label(font: SidebarStyle.headerFont)
    private let count = SidebarRowView.label(font: SidebarStyle.headerFont)
    private let chevron = NSImageView()
    var onToggle: (() -> Bool)?

    required init(key: SidebarRowKey) {
        super.init(key: key)
        chevron.setAccessibilityElement(false)
        addSubview(name)
        addSubview(count)
        addSubview(chevron)
    }

    func configure(_ row: SidebarRow) {
        name.setString(Strings.priorityNeedsYou)
        count.setString("\(row.childCount)")
        count.isHidden = !row.isCollapsed
        name.setFont(SidebarStyle.headerFont)
        count.setFont(SidebarStyle.headerFont)
        chevron.image = SidebarStyle.chevron(collapsed: row.isCollapsed)
        setAccessibilityElement(true)
        setAccessibilityRole(.disclosureTriangle)
        setAccessibilityLabel("\(name.stringValue), \(row.childCount)")
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
    }

    override func layout() {
        super.layout()
        let b = layoutBounds
        let x = SidebarStyle.columns(rowWidth: b.width).lead - SidebarStyle.labelCellPadding
        let h = ceil(name.intrinsicContentSize.height)
        let side = Metrics.smallIconSize
        // As Group by Status's header: the label's frame holds its padding (`naturalSize`), the count follows the text.
        let nameWidth = min(ceil(name.naturalSize.width), max(0, b.width - x - side - Metrics.space6))
        name.frame = NSRect(x: x, y: SidebarStyle.textY(name, centerY: b.midY), width: nameWidth, height: h)
        let namePadding = name.naturalSize.width - name.intrinsicContentSize.width
        count.frame = NSRect(x: name.frame.maxX - namePadding + Metrics.space1, y: name.frame.minY,
                             width: ceil(count.naturalSize.width), height: h)
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
