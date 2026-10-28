import AppKit
import CmuxAgentBrands
import CmuxNextDesign
import CmuxNextIcons

/// A compact tab row shown below a workspace when tab listing is enabled. It
/// reads as the workspace's child by indent alone, no bars: a grouped
/// workspace's line is the only bar in a hierarchy (cx-ai79). It draws no
/// kind or agent glyph; only a browser tab's page favicon (Lawrence
/// 2026-10-14, cx-im75u). An unread tab shows a small muted unread dot
/// at its trailing edge; its title keeps the primary color and regular weight.
/// `sidebar.tabLines` (`SidebarTabLine`, Leo 2026-10-27: "look at what's redundant and look at what's
/// useful"): by default the name leaves out what the workspace row says, a quieter detail follows it,
/// an agent's mark takes the icon slot and the tab's own status sits on the trailing column.
final class SidebarTabRowView: SidebarRowView {
    private let icon = DecorativeImageView() // the row's label names the tab
    private let title = SidebarRowView.label(font: SidebarStyle.subtitleFont)
    private let detail = SidebarRowView.label(font: SidebarStyle.subtitleFont)
    /// The tab's own status, on the trailing column as a workspace row's (the tab bar's dot).
    private let activity: StatusIndicatorView = {
        let view = StatusIndicatorView()
        (view.tracksWindowOcclusion, view.usesStatusColors) = (true, true)
        return view
    }()
    /// Whether the icon is a template agent mark (tinted with the text) rather than a page favicon.
    private var iconIsMark = false
    /// The unread dot: a workspace row's dot (`UnreadBadgeView`, same shape and size) in the quiet, muted look.
    private let unreadDot = UnreadBadgeView()
    /// The tab its workspace shows: a quiet fill marks it.
    private(set) var isFocusedTab = false
    /// Activates this tab from an accessibility AXPress.
    var onSelect: (() -> Void)?
    /// The hover ✕ (`SidebarRowCloseButton`, the workspace row's): closes this tab. Nil: no ✕.
    var onClose: (() -> Void)?
    let closeButton = SidebarIconButton.rowClose(label: Strings.closeTab)

    private struct Content: Hashable {
        var tab: SidebarTab
        var focused: Bool
        var group: GroupID?
        var groupColor: GroupColor?
        var look: SidebarTabLineLook
    }

    required init(key: SidebarRowKey) {
        super.init(key: key)
        [icon, title, detail, activity, unreadDot, closeButton].forEach(addSubview)
        unreadDot.fixedLook = .quiet
        closeButton.isHidden = true
        closeButton.onPress = { [weak self] in self?.onClose?() }
    }

    override var interactiveSubviews: [NSView] { [closeButton] }

    /// The ✕ shows or hides in `layout()`, as a workspace row's does.
    override func hoverChanged() {
        super.hoverChanged()
        needsLayout = true
    }

    override var debugIcon: String? { icon.isHidden ? nil : (iconIsMark ? "agentMark" : "favicon") }

    override func prepareForReuse(key: SidebarRowKey) {
        super.prepareForReuse(key: key)
        onSelect = nil
        onClose = nil
        lastConfiguration = nil
    }

    /// The last configure's tab and row, so a change of `sidebar.tabLines` redraws the row (`SidebarTunablesWatch`).
    private var lastConfiguration: (SidebarTab, SidebarRow, Bool)?

    func redrawLastConfiguration() {
        guard let (tab, row, focused) = lastConfiguration else { return }
        configure(tab, row: row, focused: focused)
    }

    /// `focused`: the tab its workspace shows (`SidebarWorkspace.focusedTab`).
    func configure(_ tab: SidebarTab, row: SidebarRow, focused: Bool = false) {
        lastConfiguration = (tab, row, focused)
        let look = SidebarTunablesWatch.shared.tabLook(for: self)
        let content = Content(tab: tab, focused: focused, group: row.group, groupColor: row.groupColor, look: look)
        guard needsConfigure(content) else { return }
        isFocusedTab = focused
        let line = SidebarTabLine.make(tab, look: look, terminalName: Strings.untitledTerminal)
        title.setString(line.name)
        detail.setString(line.detail ?? "")
        detail.isHidden = line.detail == nil
        // Regular weight and the primary text color, read or unread (Lawrence 2026-10-14). The workspace's focused tab
        // is marked by a quiet fill (Leo 2026-10-27: "it should also just slightly demarcate, you know, which pane
        // you're focused on, right? Like which tab within your workspace").
        title.setFont(SidebarStyle.subtitleFont)
        // A page's favicon draws as is; with the marks on, an agent's mark where there is no favicon.
        let side = SidebarStyle.tabIconSize
        let mark = look.drawsMarks && tab.favicon == nil ? tab.brand.flatMap { AgentBrandCatalog.templateImage(brand: $0, size: side) } : nil
        icon.image = tab.favicon.map { NSImage(cgImage: $0.image, size: NSSize(width: side, height: side)) } ?? mark
        iconIsMark = mark != nil
        icon.isHidden = icon.image == nil
        activity.configure(look.drawsMarks ? tab.state : .idle)
        unreadDot.configure(tab.isUnread ? .dot : .none)
        setAccessibilityElement(true)
        setAccessibilityRole(.row)
        let workspaceIdentifier = row.workspace?.rawValue ?? "unknown"
        setAccessibilityIdentifier("cmux.sidebar.tab.\(workspaceIdentifier).\(tab.id.rawValue)")
        // The dot is drawn only: the label says it ("zsh, Unread").
        let status = look.drawsMarks ? Strings.activity(tab.state) : nil
        let spoken = [line.name, line.detail, status].compactMap { $0 }.joined(separator: ", ")
        setAccessibilityLabel(tab.isUnread ? spoken + ", " + Strings.unreadDot : spoken)
        setAccessibilitySelected(focused)
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
            detail.setColor(Palette.textTertiary)
            icon.contentTintColor = iconIsMark ? Palette.textSecondary : nil
            paintFill(isHovered ? Palette.hoverFill : isFocusedTab ? Self.focusFill : nil)
        }
    }

    /// Half the hover fill: a mark, quieter than a hover and far from the selected workspace row's fill.
    static var focusFill: NSColor {
        let hover = Palette.hoverFill
        return hover.withAlphaComponent((hover.usingColorSpace(.sRGB)?.alphaComponent ?? 1) * 0.5)
    }

    override func layout() {
        super.layout()
        let b = layoutBounds
        // A grouped tab row keeps an ungrouped one's left edge (SidebarListView.frame(for:)).
        let iconSide = SidebarStyle.tabIconSize
        let iconX = SidebarStyle.titleLeading + Metrics.space3
        icon.frame = NSRect(x: iconX, y: (b.height - iconSide) / 2, width: iconSide, height: iconSide)
        // Without a favicon the title takes the icon's place (Lawrence 2026-10-23: "as left as possible").
        let textX = icon.isHidden ? iconX - SidebarStyle.labelCellPadding : icon.frame.maxX + Metrics.space2
        var trailing = b.width - SidebarStyle.horizontalInset
        // The tab's status, else its dot, centers on the trailing column, as a workspace row's does (Leo 2026-10-28:
        // "do we seriously not have these fucking things aligned? ... because it's the inner tab thing"); a dot
        // beside a status goes left of the column. On hover the ✕ takes the column (`SidebarRowCloseButton`, the
        // workspace row's) and the mark there gives way at once, never both; leaving hides the ✕ before it returns.
        let cy = b.height / 2
        let showClose = isHovered && onClose != nil
        setHoverShown(closeButton, showClose, fades: false)
        if showClose { closeButton.frame = SidebarStyle.rowCloseFrame(rowWidth: b.width, centerY: cy) }
        activity.alphaValue = showClose ? 0 : 1 // its own isHidden says whether it has a glyph
        if activity.showsGlyph {
            activity.frame = SidebarStyle.trailingColumnFrame(rowWidth: b.width, centerY: cy, side: SidebarStyle.indicatorSize)
            trailing = min(trailing, SidebarStyle.trailingColumnStart(rowWidth: b.width))
        } else {
            activity.frame = .zero
        }
        if showClose { trailing = min(trailing, SidebarStyle.trailingColumnStart(rowWidth: b.width)) }
        // A dot on the column gives way to the ✕; one left of a status stays.
        unreadDot.alphaValue = showClose && !activity.showsGlyph ? 0 : 1
        if unreadDot.state.isUnread {
            let side = SidebarStyle.dotSize
            unreadDot.frame = activity.showsGlyph
                ? NSRect(x: trailing - side - Metrics.space2, y: cy - side / 2, width: side, height: side)
                : SidebarStyle.trailingColumnFrame(rowWidth: b.width, centerY: cy, side: side)
            trailing = min(trailing, SidebarStyle.trailingColumnStart(rowWidth: b.width), unreadDot.frame.minX) - Metrics.space2
        }
        let height = title.intrinsicContentSize.height, y = (b.height - height) / 2
        guard !detail.isHidden else {
            title.frame = NSRect(x: textX, y: y, width: max(0, trailing - textX), height: height)
            return
        }
        // The name first, then the detail in what is left; a long name leaves the detail a third of the room.
        let room = max(0, trailing - textX)
        let (titleNeeds, detailNeeds) = (ceil(title.naturalSize.width), ceil(detail.naturalSize.width))
        title.frame = NSRect(x: textX, y: y, width: min(titleNeeds, room - min(detailNeeds, room / 3)), height: height)
        detail.frame = NSRect(x: title.frame.maxX, y: y, width: max(0, min(detailNeeds, trailing - title.frame.maxX)), height: height)
    }
}
