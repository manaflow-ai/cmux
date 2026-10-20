import AppKit
import CmuxNextDesign
import CmuxNextIcons

/// A compact tab row shown below a workspace when tab listing is enabled. It
/// reads as the workspace's child by indent alone, no bars: a grouped
/// workspace's line is the only bar in a hierarchy (cx-ai79). It draws no
/// kind or agent glyph; only a browser tab's page favicon (Lawrence
/// 2026-10-14, cx-im75u). Its title keeps the primary color and regular weight, read or unread.
/// With the status icon row badge (the default), a session shows one mark, its most urgent state
/// with unread folded in as a workspace row's is (the running mark while its agent works, else a
/// done mark when unread), on the workspace rows' side (`sidebar.statusIconSide`): on the right by
/// default, the only mark there (Lawrence 2026-10-19: "a single unread indicator for the right
/// side"); on the left (Debug Settings) in a fixed slot, so titles line up whether a session has a
/// state or not. With another row badge, an unread session shows a small muted unread dot at its
/// trailing edge and no status.
final class SidebarTabRowView: SidebarRowView {
    private let icon = NSImageView()
    let title = SidebarRowView.label(font: SidebarStyle.subtitleFont)
    /// The unread dot: a workspace row's dot (`UnreadBadgeView`, same shape and size) in the quiet, muted look.
    let unreadDot = UnreadBadgeView()
    /// The session's status: the shared indicator (`SidebarTab.activity`).
    let activity: StatusIndicatorView = { let view = StatusIndicatorView(); view.tracksWindowOcclusion = true; return view }()
    /// The status side, nil while workspace rows draw no status icon (`SidebarRowBadgeStyle.status`).
    private var statusSide: SidebarStatusIconSide?
    /// Activates this tab from an accessibility AXPress.
    var onSelect: (() -> Void)?
    /// The last configuration, so a Debug Settings switch of the status side redraws the row.
    private var lastConfiguration: (SidebarTab, SidebarRow, SidebarRowBadgeStyle?)?

    private struct Content: Hashable {
        var tab: SidebarTab
        var group: GroupID?
        var groupColor: GroupColor?
        var statusSide: SidebarStatusIconSide?
    }

    required init(key: SidebarRowKey) {
        super.init(key: key)
        [icon, title, unreadDot, activity].forEach(addSubview)
        unreadDot.fixedLook = .quiet
    }

    override var debugIcon: String? { icon.isHidden ? nil : "favicon" }

    override func prepareForReuse(key: SidebarRowKey) {
        super.prepareForReuse(key: key)
        onSelect = nil
    }

    /// Draws the last configuration again (a sidebar tunable changed).
    func redrawLastConfiguration() {
        guard let last = lastConfiguration else { return }
        configure(last.0, row: last.1, badgeStyle: last.2)
    }

    /// Shows `tab`; `badgeStyle` is the list's (`SidebarModel.rowBadgeStyle`), over the Debug
    /// Settings tunable, as on workspace rows.
    func configure(_ tab: SidebarTab, row: SidebarRow, badgeStyle: SidebarRowBadgeStyle? = nil) {
        lastConfiguration = (tab, row, badgeStyle)
        let tunables = SidebarTunablesWatch.shared.values(for: self)
        let side = (badgeStyle ?? tunables.rowBadge) == .status ? tunables.statusSide : nil
        // Agent work shows as its workspace row's does: only with the `working` row element on
        // (`WorkspaceRowContent.activity`).
        var tab = tab
        tab.activity = WorkspaceRowContent.activity(tab.activity, working: row.tabShowsWorking, progress: true)
        let content = Content(tab: tab, group: row.group, groupColor: row.groupColor, statusSide: side)
        guard needsConfigure(content) else { return }
        statusSide = side
        title.setString(tab.title)
        // Regular weight and the primary text color, read or unread (Lawrence 2026-10-14).
        title.setFont(SidebarStyle.subtitleFont)
        // Only a page's favicon draws, as is; no kind or agent glyph.
        let iconSide = SidebarStyle.tabIconSize
        icon.image = tab.favicon.map { NSImage(cgImage: $0.image, size: NSSize(width: iconSide, height: iconSide)) }
        icon.isHidden = icon.image == nil
        // With the status icon, unread folds into the one mark (`WorkspaceRowView.rowStatus`).
        let unread: UnreadState = tab.isUnread ? .dot : .none
        let shown: StatusIndicatorState = side == nil ? .idle : WorkspaceRowBadges(unread: unread, activity: tab.activity).first ?? .idle
        unreadDot.configure(side == nil ? unread : .none)
        activity.configure(shown)
        setAccessibilityElement(true)
        setAccessibilityRole(.row)
        let workspaceIdentifier = row.workspace?.rawValue ?? "unknown"
        setAccessibilityIdentifier("cmux.sidebar.tab.\(workspaceIdentifier).\(tab.id.rawValue)")
        setAccessibilityLabel([tab.title, side == nil ? nil : Strings.activity(shown)].compactMap { $0 }.joined(separator: ", "))
        needsLayout = true
        needsDisplay = true
    }

    /// Routes AXPress through the sidebar's shared tab selection action.
    override func accessibilityPerformPress() -> Bool {
        guard let onSelect else { return false }
        onSelect()
        return true
    }

    override func updateLayer() {
        performWithTheme {
            title.setColor(Palette.textPrimary)
            paintFill(isHovered ? Palette.hoverFill : nil)
        }
    }

    override func layout() {
        super.layout()
        let b = layoutBounds
        // A grouped tab row starts right of its group's line (SidebarListView.frame(for:)).
        let iconSide = SidebarStyle.tabIconSize, glyph = SidebarStyle.statusGlyphSize
        var iconX = SidebarStyle.titleLeading + Metrics.space3
        // The status slot on the left: kept whether the session has a state or not, so titles line up.
        if statusSide == .left {
            activity.frame = Self.snapped(NSRect(x: iconX, y: (b.height - glyph) / 2, width: glyph, height: glyph), in: window)
            iconX += glyph + Metrics.space2
        }
        icon.frame = NSRect(x: iconX, y: (b.height - iconSide) / 2, width: iconSide, height: iconSide)
        // Without a favicon the title takes the icon's place.
        let textX = icon.isHidden ? iconX - SidebarStyle.labelCellPadding : icon.frame.maxX + Metrics.space2
        // The dot sits where a workspace row's dot does: its slot at the row's trailing inset.
        var trailing = b.width - SidebarStyle.horizontalInset
        if unreadDot.state.isUnread {
            let side = SidebarStyle.dotSize
            unreadDot.frame = NSRect(x: trailing - side - Metrics.space2, y: (b.height - side) / 2, width: side, height: side)
            trailing = unreadDot.frame.minX - Metrics.space2
        }
        if statusSide == .right, activity.showsGlyph {
            activity.frame = Self.snapped(NSRect(x: trailing - glyph, y: (b.height - glyph) / 2, width: glyph, height: glyph), in: window)
            trailing = activity.frame.minX - Metrics.space2
        } else if statusSide != .left {
            activity.frame = .zero
        }
        title.frame = NSRect(x: textX, y: (b.height - title.intrinsicContentSize.height) / 2,
                             width: max(0, trailing - textX), height: title.intrinsicContentSize.height)
    }

    /// `rect` on the pixel grid of `window`.
    private static func snapped(_ rect: NSRect, in window: NSWindow?) -> NSRect {
        let scale = window?.backingScaleFactor ?? 2
        func snap(_ value: CGFloat) -> CGFloat { (value * scale).rounded() / scale }
        return NSRect(x: snap(rect.minX), y: snap(rect.minY), width: rect.width, height: rect.height)
    }
}
