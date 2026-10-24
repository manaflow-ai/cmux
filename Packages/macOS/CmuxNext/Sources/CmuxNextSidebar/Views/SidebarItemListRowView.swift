import AppKit
import CmuxNextDesign

/// A sidebar document item listed as a row (a link, a tab or an app in a
/// machine list; `SidebarRowKey.item`). It draws as a workspace row in the
/// compact density: the favicon when known, then the title in the regular
/// weight; no kind glyph, no close or more control. Hover and the one
/// selection paint the same fills; the list owns its mouse, menu and drag.
final class SidebarItemListRowView: SidebarRowView {
    private let icon = SidebarIconView()
    private let title = SidebarRowView.label(font: SidebarStyle.titleFont)
    private var hasIcon = false
    /// Archived in the sidebar document: the row draws dimmed (`SidebarStyle.archivedAlpha`).
    private var archived = false
    /// Runs the item from an accessibility AXPress.
    var onSelect: (() -> Void)?

    private struct Content: Hashable {
        var item: SidebarListItem
        var favicon: SidebarFavicon?
        var fontSize: CGFloat
    }

    required init(key: SidebarRowKey) {
        super.init(key: key)
        [icon, title].forEach(addSubview)
    }

    override var debugIcon: String? { hasIcon ? "favicon" : nil }
    override var debugArchived: Bool { archived }
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
        archived = item.isArchived
        icon.alphaValue = archived ? SidebarStyle.archivedAlpha : 1
        setAccessibilityElement(true)
        setAccessibilityRole(.row)
        setAccessibilityIdentifier("cmux.sidebar.item.\(item.id)")
        setAccessibilityLabel(item.title)
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
            title.textColor = archived ? Palette.textPrimary.withAlphaComponent(SidebarStyle.archivedAlpha) : Palette.textPrimary
            paintFill(isSelected ? Palette.selectionFill : isHovered ? Palette.hoverFill : nil)
        }
    }

    override func layout() {
        super.layout()
        let b = layoutBounds
        // The workspace row's geometry: the icon in the leading slot, else the title at the leading inset.
        let leading = SidebarStyle.horizontalInset
        let side: CGFloat = hasIcon ? SidebarStyle.iconBox : 0
        icon.frame = NSRect(x: leading, y: (b.height - side) / 2, width: side, height: side)
        let textX = SidebarStyle.titleTextX(leading: leading, iconSide: side) - WorkspaceRowView.labelInset
        let height = ceil(title.intrinsicContentSize.height)
        title.frame = NSRect(x: textX, y: (b.height - height) / 2, width: max(0, b.width - textX - SidebarStyle.horizontalInset), height: height)
    }
}
