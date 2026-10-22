import AppKit
import CmuxNextDesign

/// A sidebar document item listed as a row (a link, a tab or an app in a
/// machine list; `SidebarRowKey.item`). It draws as a workspace row in the
/// compact density: the favicon when known, then the title in the regular
/// weight; no kind glyph, no close or more control. A closed pinned
/// workspace's row (`SidebarListItem.pinned`) draws the workspace row's pin
/// glyph before its title. Hover and the one selection paint the same
/// fills; the list owns its mouse, menu and drag.
final class SidebarItemListRowView: SidebarRowView {
    private let icon = SidebarIconView()
    private let title = SidebarRowView.label(font: SidebarStyle.titleFont)
    private let pinMark = DecorativeImageView() // the row's label says it is pinned
    private var hasIcon = false
    /// Runs the item from an accessibility AXPress.
    var onSelect: (() -> Void)?

    private struct Content: Hashable {
        var item: SidebarListItem
        var favicon: SidebarFavicon?
        var fontSize: CGFloat
    }

    required init(key: SidebarRowKey) {
        super.init(key: key)
        pinMark.imageScaling = .scaleProportionallyDown
        pinMark.isHidden = true
        pinMark.setAccessibilityElement(false)
        [icon, pinMark, title].forEach(addSubview)
    }

    override var debugIcon: String? { hasIcon ? "favicon" : nil }
    override var debugIconAddress: String? { hasIcon ? iconAddress : nil }
    private var iconAddress: String?
    override var titleFrame: NSRect { title.frame }
    override var titleFont: NSFont { title.font ?? SidebarStyle.titleFont }

    override func prepareForReuse(key: SidebarRowKey) {
        super.prepareForReuse(key: key)
        onSelect = nil
    }

    func configure(_ item: SidebarListItem, favicon: SidebarFavicon?, row: SidebarRow) {
        guard needsConfigure(Content(item: item, favicon: favicon, fontSize: SidebarStyle.titleFont.pointSize)) else { return }
        title.stringValue = item.title
        title.font = SidebarStyle.titleFont
        hasIcon = favicon != nil
        iconAddress = item.iconAddress
        icon.configure(icon: favicon.map(WorkspaceIcon.favicon))
        icon.isHidden = !hasIcon
        pinMark.image = item.pinned
            ? NSImage.icon(.statePinned, size: .iconRowSize(forLabelPointSize: SidebarStyle.indicatorSize - Metrics.space1)) : nil
        pinMark.isHidden = pinMark.image == nil
        pinMark.setAccessibilityIdentifier("cmux.sidebar.item.\(item.id).pin")
        setAccessibilityElement(true)
        setAccessibilityRole(.row)
        setAccessibilityIdentifier("cmux.sidebar.item.\(item.id)")
        setAccessibilityLabel(item.pinned ? [item.title, Strings.pinned].joined(separator: ", ") : item.title)
        needsLayout = true
        needsDisplay = true
    }

    override func accessibilityPerformPress() -> Bool {
        guard let onSelect else { return false }
        onSelect()
        return true
    }

    override func updateLayer() {
        performWithTheme {
            title.textColor = Palette.textPrimary
            pinMark.setTint(Palette.textTertiary)
            paintFill(isSelected ? Palette.selectionFill : isHovered ? Palette.hoverFill : nil)
        }
    }

    override func layout() {
        super.layout()
        let b = layoutBounds
        // The workspace row's geometry: the icon in the leading slot, drawn or empty, then the title.
        let leading = SidebarStyle.horizontalInset
        let side: CGFloat = hasIcon ? SidebarStyle.iconBox : 0
        icon.frame = NSRect(x: leading, y: (b.height - side) / 2, width: side, height: side)
        var textX = SidebarStyle.titleTextX(leading: leading) - WorkspaceRowView.labelInset
        if !pinMark.isHidden {
            // The workspace row's pin, at its place: before the title (`WorkspaceRowView+Rendering`).
            let side = SidebarStyle.indicatorSize
            pinMark.frame = NSRect(x: textX + WorkspaceRowView.labelInset, y: (b.height - side) / 2, width: side, height: side)
            textX = pinMark.frame.maxX + Metrics.space1
        }
        let height = ceil(title.intrinsicContentSize.height)
        title.frame = NSRect(x: textX, y: (b.height - height) / 2, width: max(0, b.width - textX - SidebarStyle.horizontalInset), height: height)
    }
}
