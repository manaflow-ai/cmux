import AppKit
import CmuxNextDesign
import QuartzCore

final class WorkspaceRowView: SidebarRowView {
    private let icon = SidebarIconView()
    private let title = SidebarRowView.label(font: SidebarStyle.titleFont, color: Palette.textPrimary)
    private let subtitle = SidebarRowView.label(font: SidebarStyle.subtitleFont, color: Palette.textSecondary)
    private let activity = ActivityIndicatorView()
    private let badge = UnreadBadgeView()
    private let rail = CALayer()
    let closeButton = SidebarIconButton(symbol: "xmark", pointSize: { Metrics.smallIconSize - Metrics.space2 }, weight: .bold, label: Strings.closeButton)

    private var hasSubtitle = false
    private var grouped = false
    private var groupColor: GroupColor?
    private var iconKind: WorkspaceIcon?
    /// Selected but not active (the active row sits on the shared pill).
    var isSecondarySelected = false { didSet { if isSecondarySelected != oldValue { needsDisplay = true } } }
    /// A tab dragged from a pane would move into this workspace.
    var isDropTarget = false { didSet { if isDropTarget != oldValue { needsDisplay = true } } }
    var onClose: (() -> Void)?

    required init(key: SidebarRowKey) {
        super.init(key: key)
        rail.cornerRadius = 1
        layer?.addSublayer(rail)
        [icon, title, subtitle, activity, badge, closeButton].forEach(addSubview)
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
        var groupColor: GroupColor?
        var compact: Bool
        var fontSize: CGFloat
        var iconSize: CGFloat
    }

    func configure(_ ws: SidebarWorkspace, row: SidebarRow, compact: Bool) {
        let content = Content(
            ws: ws, group: row.group, groupColor: row.groupColor, compact: compact,
            fontSize: SidebarStyle.titleFont.pointSize, iconSize: Metrics.smallIconSize
        )
        guard needsConfigure(content) else { return }
        self.compact = compact
        grouped = row.group != nil
        groupColor = row.groupColor
        icon.configure(icon: ws.icon, title: ws.title, compact: compact)
        iconKind = ws.icon
        title.stringValue = ws.title
        title.font = ws.unread.isUnread ? SidebarStyle.titleUnreadFont : SidebarStyle.titleFont
        subtitle.font = SidebarStyle.subtitleFont
        // Only live status earns a second line; the cwd stays in the tooltip.
        subtitle.stringValue = ws.liveDetail ?? ""
        hasSubtitle = ws.liveDetail != nil
        activity.configure(ws.activity)
        // Icons-only rows mark unread with a dot; a count would cover the icon.
        badge.configure(compact && ws.unread.isUnread ? .dot : ws.unread)
        toolTip = compact ? ws.title : ws.subtitle.flatMap { $0.isEmpty ? nil : $0 }
        setAccessibilityElement(true)
        setAccessibilityRole(.row)
        setAccessibilityLabel(accessibilityText(ws))
        needsLayout = true
        needsDisplay = true
    }

    private func accessibilityText(_ ws: SidebarWorkspace) -> String {
        var parts = [ws.title]
        if let s = ws.liveDetail { parts.append(s) }
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
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        rail.backgroundColor = groupColor.map { SidebarStyle.color($0).withAlphaComponent(0.85).cgColor }
        // Grouped rows show membership by indent; the rail only helps in
        // icons-only mode, where there is no indent.
        rail.isHidden = !(grouped && compact)
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        let b = layoutBounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        if compact {
            let side = SidebarStyle.iconBox
            icon.frame = NSRect(x: (b.width - side) / 2, y: (b.height - side) / 2, width: side, height: side)
            [title, subtitle, closeButton].forEach { $0.isHidden = true }
            let dot = SidebarStyle.dotSize
            let isDot = badge.state == .dot || badge.state == .none
            let bw = isDot ? dot : min(badge.preferredWidth, side)
            let bh = isDot ? dot : SidebarStyle.badgeHeight
            badge.frame = NSRect(x: icon.frame.maxX - bw + Metrics.space2, y: icon.frame.minY - Metrics.space2, width: bw, height: bh)
            let ind = SidebarStyle.indicatorSize
            activity.frame = NSRect(x: icon.frame.maxX - ind / 2, y: icon.frame.maxY - ind / 2, width: ind, height: ind)
            rail.frame = CGRect(x: Metrics.space1, y: Metrics.space4, width: SidebarStyle.railWidth, height: b.height - Metrics.space6)
            needsDisplay = true
            return
        }

        let indent: CGFloat = grouped ? SidebarStyle.groupIndent : 0
        rail.frame = CGRect(x: Metrics.space2, y: Metrics.space3, width: SidebarStyle.railWidth, height: b.height - Metrics.space5)
        // Text-first: the title starts at the inset unless the user chose
        // an icon (a color is a small dot, a symbol a glyph).
        let leading = SidebarStyle.horizontalInset + indent
        let side: CGFloat
        switch iconKind {
        case nil: side = 0
        case .swatch?: side = SidebarStyle.dotSize + Metrics.space1
        case .symbol?: side = SidebarStyle.iconBox
        }
        icon.frame = NSRect(x: leading, y: (b.height - side) / 2, width: side, height: side)

        // Trailing cluster, right to left: close-or-badge, then activity.
        var trailing = b.width - Metrics.space3
        let showClose = isHovered
        closeButton.isHidden = !showClose
        let control = SidebarStyle.controlSize
        if showClose {
            closeButton.frame = NSRect(x: trailing - control, y: (b.height - control) / 2, width: control, height: control)
            trailing -= control + Metrics.space2
            badge.isHidden = true
        } else if badge.state.isUnread {
            badge.isHidden = false
            let w = badge.preferredWidth
            let h = badge.state == .dot ? SidebarStyle.dotSize : SidebarStyle.badgeHeight
            badge.frame = NSRect(x: trailing - w - (badge.state == .dot ? Metrics.space2 : 0), y: (b.height - h) / 2, width: w, height: h)
            trailing = badge.frame.minX - Metrics.space2
        }
        if activity.activity != .idle {
            let ind = SidebarStyle.indicatorSize
            activity.frame = NSRect(x: trailing - ind, y: (b.height - ind) / 2, width: ind, height: ind)
            trailing -= ind + Metrics.space2
        }

        let textX = side > 0 ? icon.frame.maxX + Metrics.space3 : leading
        let textW = max(0, trailing - textX)
        title.isHidden = renaming
        let th = ceil(title.intrinsicContentSize.height)
        if hasSubtitle {
            let sh = ceil(subtitle.intrinsicContentSize.height)
            let total = th + sh
            let top = (b.height - total) / 2
            title.frame = NSRect(x: textX, y: top, width: textW, height: th)
            subtitle.frame = NSRect(x: textX, y: top + th, width: textW, height: sh)
            subtitle.isHidden = false
        } else {
            title.frame = NSRect(x: textX, y: (b.height - th) / 2, width: textW, height: th)
            subtitle.isHidden = true
        }
        needsDisplay = true
    }
}

// MARK: - Group header
