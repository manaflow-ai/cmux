import AppKit
import CmuxNextDesign

/// A sidebar document item listed as a row (a link, a tab or an app in a
/// machine list; `SidebarRowKey.item`). It draws as a workspace row in the
/// compact density: the favicon when known, then the title in the regular
/// weight; no kind glyph, no close or more control. A built-in carries its
/// band look (`SidebarModel.itemInfo`): the Chief's picture, its status and
/// its unread badge or dot, wherever it is listed. Hover and the one
/// selection paint the same fills; the list owns its mouse, menu and drag.
final class SidebarItemListRowView: SidebarRowView {
    private let icon = SidebarIconView()
    private let title = SidebarRowView.label(font: SidebarStyle.titleFont)
    private let badge = UnreadBadgeView()
    private let activity: StatusIndicatorView = {
        let view = StatusIndicatorView()
        (view.tracksWindowOcclusion, view.usesStatusColors) = (true, true) // the band's status colors (`SidebarItemRowView`)
        return view
    }()
    private var hasIcon = false
    /// Archived in the sidebar document: the row draws dimmed (`SidebarStyle.archivedAlpha`).
    private var archived = false
    /// Runs the item from an accessibility AXPress.
    var onSelect: (() -> Void)?

    private struct Content: Hashable {
        var item: SidebarListItem
        var favicon: SidebarFavicon?
        var info: SidebarItemInfo?
        var fontSize: CGFloat
    }

    required init(key: SidebarRowKey) {
        super.init(key: key)
        [icon, title, badge, activity].forEach(addSubview)
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

    /// `info`: a built-in's band look (its picture, status and badge), nil for a link, a tab or an app.
    func configure(_ item: SidebarListItem, favicon: SidebarFavicon?, info: SidebarItemInfo? = nil, row: SidebarRow) {
        guard needsConfigure(Content(item: item, favicon: favicon, info: info, fontSize: SidebarStyle.titleFont.pointSize)) else { return }
        title.stringValue = item.title
        title.font = SidebarStyle.titleFont
        let picture = info?.favicon ?? favicon
        hasIcon = picture != nil
        iconAddress = item.iconAddress
        icon.configure(icon: picture.map(WorkspaceIcon.favicon))
        icon.isHidden = !hasIcon
        badge.notificationDot = info?.unreadDot == true // Home's blue unread dot, as the band draws it
        badge.configure(Self.unread(info))
        activity.configure(info?.activity ?? .idle, style: info?.activityStyle)
        setAccessibilityValue(info.flatMap { $0.unreadDot ? Strings.unreadDot : $0.badge.map { String($0) } })
        archived = item.isArchived
        icon.alphaValue = archived ? SidebarStyle.archivedAlpha : 1
        setAccessibilityElement(true)
        setAccessibilityRole(.row)
        setAccessibilityIdentifier("cmux.sidebar.item.\(item.id)")
        setAccessibilityLabel(item.title)
        needsLayout = true
        needsDisplay = true
    }

    /// A built-in's unread dot, else its count, as its band row shows them.
    private static func unread(_ info: SidebarItemInfo?) -> UnreadState {
        guard let info else { return UnreadState.none }
        if info.unreadDot { return .dot }
        return info.badge.map(UnreadState.count) ?? UnreadState.none
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
        // The badge and the status trail it, as on the item's band row.
        let badgeWidth = badge.isHidden ? 0 : badge.preferredWidth
        let badgeHeight = badge.state == .dot ? badgeWidth : SidebarStyle.badgeHeight
        let badgeX = b.width - SidebarStyle.horizontalInset - badgeWidth
        badge.frame = NSRect(x: badgeX, y: (b.height - badgeHeight) / 2, width: badgeWidth, height: badgeHeight)
        let indicator = SidebarStyle.indicatorSize
        let activityX = badgeX - (activity.showsGlyph ? indicator + (badge.isHidden ? 0 : Metrics.space2) : 0)
        activity.frame = activity.showsGlyph ? NSRect(x: activityX, y: (b.height - indicator) / 2, width: indicator, height: indicator) : .zero
        let height = ceil(title.intrinsicContentSize.height)
        let textEnd = activity.showsGlyph || !badge.isHidden ? activityX - Metrics.space2 : b.width - SidebarStyle.horizontalInset
        title.frame = NSRect(x: textX, y: (b.height - height) / 2, width: max(0, textEnd - textX), height: height)
    }
}
