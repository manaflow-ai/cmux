import AppKit
import CmuxNextDesign
import QuartzCore

final class WorkspaceRowView: SidebarRowView {
    private let icon = SidebarIconView()
    private let title = SidebarRowView.label(font: SidebarStyle.titleFont, color: Palette.textPrimary)
    private let statusBlock = WorkspaceStatusView()
    private let activity = ActivityIndicatorView()
    private let badge = UnreadBadgeView()
    let closeButton = SidebarIconButton(symbol: "xmark", pointSize: { Metrics.smallIconSize - Metrics.space2 }, weight: .bold, label: Strings.closeButton)

    private var hasStatus = false
    private var grouped = false
    private var iconKind: WorkspaceIcon?
    /// Selected but not active (the active row sits on the shared pill).
    var isSecondarySelected = false { didSet { if isSecondarySelected != oldValue { needsDisplay = true } } }
    /// A tab dragged from a pane would move into this workspace.
    var isDropTarget = false { didSet { if isDropTarget != oldValue { needsDisplay = true } } }
    var onClose: (() -> Void)?

    required init(key: SidebarRowKey) {
        super.init(key: key)
        [icon, title, statusBlock, activity, badge, closeButton].forEach(addSubview)
        closeButton.isHidden = true
        closeButton.onPress = { [weak self] in self?.onClose?() }
    }

    override var interactiveSubviews: [NSView] { [closeButton] }

    override func prepareForReuse(key: SidebarRowKey) {
        super.prepareForReuse(key: key)
        isSecondarySelected = false
        isDropTarget = false
        onClose = nil
    }

    private struct Content: Hashable {
        var ws: SidebarWorkspace
        var group: GroupID?
        var fontSize: CGFloat
        var iconSize: CGFloat
    }

    func configure(_ ws: SidebarWorkspace, row: SidebarRow) {
        let content = Content(
            ws: ws, group: row.group,
            fontSize: SidebarStyle.titleFont.pointSize, iconSize: Metrics.smallIconSize
        )
        guard needsConfigure(content) else { return }
        grouped = row.group != nil
        icon.configure(icon: ws.icon)
        iconKind = ws.icon
        title.stringValue = ws.title
        title.font = ws.unread.isUnread ? SidebarStyle.titleUnreadFont : SidebarStyle.titleFont
        // Only live status earns more lines; the cwd is in the hover card.
        hasStatus = ws.liveStatus != nil
        statusBlock.configure(ws.liveStatus ?? SidebarWorkspaceStatus())
        activity.configure(ws.activity)
        badge.configure(ws.unread)
        // The workspace hover card shows the cwd (and CPU and memory).
        toolTip = nil
        setAccessibilityElement(true)
        setAccessibilityRole(.row)
        setAccessibilityLabel(accessibilityText(ws))
        needsLayout = true
        needsDisplay = true
    }

    private func accessibilityText(_ ws: SidebarWorkspace) -> String {
        var parts = [ws.title]
        if let s = ws.liveStatus?.searchText, !s.isEmpty { parts.append(s) }
        if let s = ws.subtitle, !s.isEmpty { parts.append(s) }
        switch ws.unread {
        case let .count(n) where n > 0: parts.append(Strings.unreadCount(n))
        case .dot: parts.append(Strings.unreadDot)
        default: break
        }
        switch ws.activity {
        case .running: parts.append(Strings.activityRunning)
        case .needsInput: parts.append(Strings.activityNeedsInput)
        case .error: parts.append(Strings.activityError)
        case .idle: break
        }
        return parts.joined(separator: ", ")
    }

    override var titleFrame: NSRect { title.frame }
    override var titleFont: NSFont { title.font ?? SidebarStyle.titleFont }
    private var renaming = false
    override func setTitleHidden(_ hidden: Bool) {
        renaming = hidden
        title.isHidden = hidden
    }

    override func hoverChanged() {
        super.hoverChanged()
        needsLayout = true
    }

    override func updateLayer() {
        guard let layer else { return }
        // Fills only, no borders: drop target, multi-selection, hover.
        if isDropTarget {
            layer.backgroundColor = resolvedCGColor(Palette.selectionFill)
        } else if isSecondarySelected {
            layer.backgroundColor = resolvedCGColor(Palette.secondarySelectionFill)
        } else if isHovered {
            layer.backgroundColor = resolvedCGColor(Palette.hoverFill)
        } else {
            layer.backgroundColor = nil
        }
    }

    override func layout() {
        super.layout()
        let b = layoutBounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        // A row with status keeps its icon and trailing controls on the title line.
        let lineBox = hasStatus ? min(b.height, SidebarLayoutMetrics.standard.rowHeight) : b.height
        let indent: CGFloat = grouped ? SidebarStyle.groupIndent : 0
        // Text-first: the title starts at the inset unless the user chose
        // an icon (a color is a small dot, a symbol a glyph).
        let leading = SidebarStyle.horizontalInset + indent
        let side: CGFloat
        switch iconKind {
        case nil: side = 0
        case .swatch?: side = SidebarStyle.dotSize + Metrics.space1
        case .symbol?: side = SidebarStyle.iconBox
        }
        icon.frame = NSRect(x: leading, y: (lineBox - side) / 2, width: side, height: side)

        // Trailing cluster, right to left: close-or-badge, then activity.
        var trailing = b.width - Metrics.space3
        let showClose = isHovered
        closeButton.isHidden = !showClose
        let control = SidebarStyle.controlSize
        if showClose {
            closeButton.frame = NSRect(x: trailing - control, y: (lineBox - control) / 2, width: control, height: control)
            trailing -= control + Metrics.space2
            badge.isHidden = true
        } else if badge.state.isUnread {
            badge.isHidden = false
            let w = badge.preferredWidth
            let h = badge.state == .dot ? SidebarStyle.dotSize : SidebarStyle.badgeHeight
            badge.frame = NSRect(x: trailing - w - (badge.state == .dot ? Metrics.space2 : 0), y: (lineBox - h) / 2, width: w, height: h)
            trailing = badge.frame.minX - Metrics.space2
        }
        if activity.activity != .idle {
            let ind = SidebarStyle.indicatorSize
            activity.frame = NSRect(x: trailing - ind, y: (lineBox - ind) / 2, width: ind, height: ind)
            trailing -= ind + Metrics.space2
        }

        let textX = side > 0 ? icon.frame.maxX + Metrics.space3 : leading
        let textW = max(0, trailing - textX)
        title.isHidden = renaming
        let th = ceil(title.intrinsicContentSize.height)
        if hasStatus {
            // The title stays where a one-line row has it; the status block
            // fills the height the layout added below it.
            title.frame = NSRect(x: textX, y: (lineBox - th) / 2, width: textW, height: th)
            statusBlock.frame = NSRect(x: textX, y: title.frame.maxY, width: textW, height: max(0, b.height - title.frame.maxY))
            statusBlock.isHidden = false
        } else {
            title.frame = NSRect(x: textX, y: (b.height - th) / 2, width: textW, height: th)
            statusBlock.isHidden = true
        }
        needsDisplay = true
    }
}

// MARK: - Group header
