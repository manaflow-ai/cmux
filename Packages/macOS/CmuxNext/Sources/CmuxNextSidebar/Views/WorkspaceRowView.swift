import AppKit
import CmuxNextDesign
import QuartzCore

final class WorkspaceRowView: SidebarRowView {
    private let icon = SidebarIconView()
    /// Fades a clipped title and scrolls it while the pointer rests on the
    /// row (TitleFade); NSTextField would end it in an ellipsis instead.
    let title = MarqueeLabel()
    private let subtitle = SidebarRowView.label(font: SidebarStyle.subtitleFont)
    private let activity = StatusIndicatorView()
    private let badge = UnreadBadgeView()
    let closeButton = SidebarIconButton(symbol: "xmark", pointSize: { Metrics.smallIconSize - Metrics.space2 }, weight: .bold, label: Strings.closeButton)

    private var hasSubtitle = false
    private var grouped = false
    private var iconKind: WorkspaceIcon?
    /// Selected but not active (the active row sits on the shared pill).
    var isSecondarySelected = false { didSet { if isSecondarySelected != oldValue { needsDisplay = true } } }
    /// A tab dragged from a pane would move into this workspace.
    var isDropTarget = false { didSet { if isDropTarget != oldValue { needsDisplay = true } } }
    var onClose: (() -> Void)?

    required init(key: SidebarRowKey) {
        super.init(key: key)
        title.font = SidebarStyle.titleFont
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
        title.stopMarquee()
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
        subtitle.font = SidebarStyle.subtitleFont
        // Only live status earns a second line; the cwd is in the hover card.
        subtitle.stringValue = ws.liveDetail ?? ""
        hasSubtitle = ws.liveDetail != nil
        activity.configure(ws.activity, style: ws.activityStyle)
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
        if let s = ws.liveDetail { parts.append(s) }
        if let s = ws.subtitle, !s.isEmpty { parts.append(s) }
        switch ws.unread {
        case let .count(n) where n > 0: parts.append(Strings.unreadCount(n))
        case .dot: parts.append(Strings.unreadDot)
        default: break
        }
        if let text = Strings.activity(ws.activity) { parts.append(text) }
        return parts.joined(separator: ", ")
    }

    /// Where an NSTextField label with this text would sit (inline rename
    /// aligns its field to it): the glyphs start one cell inset inside it.
    override var titleFrame: NSRect { title.frame.insetBy(dx: -Self.labelInset, dy: 0) }
    override var titleFont: NSFont { title.font }
    private var renaming = false
    override func setTitleHidden(_ hidden: Bool) {
        renaming = hidden
        title.isHidden = hidden
        if hidden { title.stopMarquee() }
    }

    /// An AppKit label cell draws its text this far inside its frame; the
    /// marquee label draws at its edge, so it sits this much further in.
    static let labelInset = Metrics.space1

    override func hoverChanged() {
        super.hoverChanged()
        needsLayout = true
        guard isHovered, !renaming else {
            title.stopMarquee()
            return
        }
        // The x appears on hover and narrows the title first. Under Reduce
        // Motion no marquee runs: the workspace hover card shows the whole
        // name (wrapped), so no second popover (a tooltip) shows with it.
        layoutSubtreeIfNeeded()
        title.startMarquee()
    }

    override func updateLayer() {
        guard let layer else { return }
        performWithTheme {
            title.textColor = Palette.textPrimary
            subtitle.textColor = Palette.textSecondary
            // Fills only, no borders: drop target, multi-selection, hover.
            if isDropTarget {
                layer.backgroundColor = Palette.selectionFill.cgColor
            } else if isSecondarySelected {
                layer.backgroundColor = Palette.secondarySelectionFill.cgColor
            } else if isHovered {
                layer.backgroundColor = Palette.hoverFill.cgColor
            } else {
                layer.backgroundColor = nil
            }
        }
    }

    override func layout() {
        super.layout()
        let b = layoutBounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

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
        if activity.showsGlyph {
            let ind = SidebarStyle.indicatorSize
            activity.frame = NSRect(x: trailing - ind, y: (b.height - ind) / 2, width: ind, height: ind)
            trailing -= ind + Metrics.space2
        }

        let textX = side > 0 ? icon.frame.maxX + Metrics.space3 : leading
        let textW = max(0, trailing - textX)
        title.isHidden = renaming
        // The marquee fades glyphs out across the padding left of them.
        let inset = Self.labelInset
        title.leadingPadding = textX + inset - (side > 0 ? icon.frame.maxX : indent)
        title.fadeWidth = SidebarStyle.titleFadeWidth
        let th = ceil(title.intrinsicContentSize.height)
        let titleWidth = max(0, textW - 2 * inset)
        if hasSubtitle {
            let sh = ceil(subtitle.intrinsicContentSize.height)
            let total = th + sh
            let top = (b.height - total) / 2
            title.frame = NSRect(x: textX + inset, y: top, width: titleWidth, height: th)
            subtitle.frame = NSRect(x: textX, y: top + th, width: textW, height: sh)
            subtitle.isHidden = false
        } else {
            title.frame = NSRect(x: textX + inset, y: (b.height - th) / 2, width: titleWidth, height: th)
            subtitle.isHidden = true
        }
        needsDisplay = true
    }
}

// MARK: - Group header
