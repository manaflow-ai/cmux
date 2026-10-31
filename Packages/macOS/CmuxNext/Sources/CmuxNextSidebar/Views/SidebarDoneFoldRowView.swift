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

    required init(key: SidebarRowKey) {
        super.init(key: key)
        addSubview(chevron)
        addSubview(name)
    }

    func configure(_ row: SidebarRow) {
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
    }

    override func layout() {
        super.layout()
        let b = layoutBounds
        let columns = SidebarStyle.columns(rowWidth: b.width)
        let h = ceil(name.intrinsicContentSize.height)
        // Done and Show N more use the shared trailing fold column; their label uses the common text line.
        chevron.frame = columns.trailingFrame(centerY: b.midY, side: SidebarStyle.controlSize)
        let x = columns.text(hasLeadingMark: false) - SidebarStyle.labelCellPadding
        name.frame = NSRect(x: x, y: columns.textOriginY(centerY: b.midY, baseline: name.firstBaselineOffsetFromTop,
                                                           capHeight: name.font?.capHeight ?? SidebarStyle.headerFont.capHeight),
                             width: max(0, columns.textEnd(trailingMarks: 1) - x), height: h)
        needsDisplay = true
    }

    override func updateLayer() {
        performWithTheme {
            name.setColor(Palette.textSecondary)
            chevron.contentTintColor = Palette.textSecondary
        }
    }
}
