import AppKit
import Observation
import CmuxAgentBrands
import CmuxNextDesign
import QuartzCore

final class WorkspaceRowView: SidebarRowView {
    let icon = SidebarIconView()
    /// Fades a clipped title and scrolls it while the pointer rests on the
    /// row (TitleFade); NSTextField would end it in an ellipsis instead.
    let title = MarqueeLabel()
    private let subtitle = SidebarRowView.label(font: SidebarStyle.subtitleFont)
    private let activity = StatusIndicatorView()
    /// The running agent's brand mark (`SidebarAgentMarkVariant`); hidden when off.
    private let agentMark = NSImageView()
    private var agentMarkVariant = SidebarAgentMarkVariant.off
    /// The last configuration, so a Debug Settings switch of `sidebar.agentMark` redraws the row.
    private var lastConfiguration: (SidebarWorkspace, SidebarRow)?
    private var activityState = StatusIndicatorState.idle
    private let badge = UnreadBadgeView()
    /// A muted workspace (`notifications.mutedWorkspaces`): a quiet bell-slash
    /// in the trailing cluster, in the tertiary text color; hidden otherwise.
    let mutedMark = NSImageView()
    /// A single colored segment connects grouped workspace rows.
    private let groupRail = CALayer()
    let closeButton = SidebarIconButton(symbol: "xmark", pointSize: { Metrics.smallIconSize - Metrics.space2 }, weight: .bold, label: Strings.closeButton)
    /// `sidebar.showWorkspaceTabs`: hides or lists the workspace's tabs. Always drawn
    /// while the setting is on (never on hover), so rows never shift.
    let disclosureButton = SidebarIconButton(symbol: "chevron.right", pointSize: { Metrics.smallIconSize - Metrics.space2 }, weight: .semibold,
                                             label: Strings.showTabs)
    /// `sidebar.workspaceRow.tabCount`: the workspace's tab count, in a fixed-width slot.
    private let tabCount = SidebarRowView.label(font: SidebarStyle.subtitleFont)
    /// `sidebar.workspaceRow.pullRequest`: the PR / CI badge a hook reported.
    private let prBadge = SidebarRowView.label(font: SidebarStyle.subtitleFont)
    private var badgeText: String?
    private var disclosure: SidebarTabDisclosure?
    private var count: Int?

    /// Progress under the row (`SidebarWorkspace.progress`): a track and a
    /// fill; an indeterminate one fills the whole track, dimmed.
    private let progressTrack = CALayer()
    private let progressFill = CALayer()
    private var progress: SidebarProgress?
    private var hasSubtitle = false
    private var grouped = false
    /// The group band's frame (`GroupLabelBandTests`).
    var groupBandFrame: NSRect { groupRail.frame }
    var isGroupBandHidden: Bool { groupRail.isHidden }
    private var groupColor: GroupColor?
    private var lastInGroup = false
    private var iconKind: WorkspaceIcon?
    /// Selected but not active (the active row paints the selection fill).
    var isSecondarySelected = false { didSet { if isSecondarySelected != oldValue { needsDisplay = true } } }
    /// A tab dragged from a pane would move into this workspace.
    var isDropTarget = false { didSet { if isDropTarget != oldValue { needsDisplay = true } } }
    var onClose: (() -> Void)?
    /// Activates this workspace from an accessibility AXPress.
    var onSelect: (() -> Void)?
    var onToggleTabs: (() -> Void)?
    /// The row draws a placeholder bar instead of a title.
    private(set) var isShowingPlaceholder = false
    /// The row's workspace can close (`SidebarWorkspace.isClosable`); the
    /// home row shows no close button.
    private(set) var isClosable = true
    /// A static tonal bar where the title goes (no shimmer).
    private let placeholderBar = NSView()
    /// The bar's share of the text width, varied per row so a column of
    /// placeholders does not read as one block.
    private var placeholderFraction: CGFloat = 0.6

    required init(key: SidebarRowKey) {
        super.init(key: key)
        title.font = SidebarStyle.titleFont
        agentMark.imageScaling = .scaleProportionallyDown
        agentMark.isHidden = true
        mutedMark.imageScaling = .scaleProportionallyDown
        mutedMark.isHidden = true
        mutedMark.setAccessibilityElement(false)
        [icon, title, subtitle, activity, agentMark, mutedMark, badge, closeButton, disclosureButton, tabCount, prBadge, placeholderBar]
            .forEach(addSubview)
        disclosureButton.isHidden = true
        tabCount.isHidden = true
        prBadge.isHidden = true
        prBadge.lineBreakMode = .byTruncatingTail
        tabCount.alignment = .right
        tabCount.font = .monospacedDigitSystemFont(ofSize: SidebarStyle.subtitleFont.pointSize, weight: .regular)
        progressTrack.addSublayer(progressFill)
        progressTrack.isHidden = true
        layer?.addSublayer(progressTrack)
        layer?.addSublayer(groupRail)
        closeButton.isHidden = true
        placeholderBar.wantsLayer = true
        placeholderBar.layer?.cornerRadius = SidebarStyle.placeholderBarHeight / 2
        placeholderBar.isHidden = true
        closeButton.onPress = { [weak self] in self?.onClose?() }
        disclosureButton.onPress = { [weak self] in self?.onToggleTabs?() }
    }

    override var interactiveSubviews: [NSView] { [closeButton, disclosureButton] }

    /// Reads the agent mark setting and redraws the row once when it changes (no polling).
    private func observedAgentMarkVariant() -> SidebarAgentMarkVariant {
        withObservationTracking {
            SidebarTunables.agentMark.value
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, let last = self.lastConfiguration else { return }
                self.configure(last.0, row: last.1)
            }
        }
    }

    override func prepareForReuse(key: SidebarRowKey) {
        super.prepareForReuse(key: key)
        isSecondarySelected = false
        isDropTarget = false
        onClose = nil
        onSelect = nil
        onToggleTabs = nil
        title.stopMarquee()
    }

    private struct Content: Hashable {
        var ws: SidebarWorkspace
        var group: GroupID?
        var groupColor: GroupColor?
        var lastInGroup: Bool
        var fontSize: CGFloat
        var iconSize: CGFloat
        var agentMark: SidebarAgentMarkVariant
        var disclosure: SidebarTabDisclosure?
        var row: WorkspaceRowContent?
    }

    func configure(_ ws: SidebarWorkspace, row: SidebarRow) {
        lastConfiguration = (ws, row)
        let content = Content(
            ws: ws, group: row.group, groupColor: row.groupColor, lastInGroup: row.isLastInGroup,
            fontSize: SidebarStyle.titleFont.pointSize, iconSize: Metrics.smallIconSize,
            agentMark: observedAgentMarkVariant(),
            disclosure: row.tabDisclosure, row: row.content
        )
        guard needsConfigure(content) else { return }
        grouped = row.group != nil
        groupColor = row.groupColor
        lastInGroup = row.isLastInGroup
        isShowingPlaceholder = ws.rowState == .placeholder
        isClosable = ws.isClosable
        placeholderFraction = SidebarStyle.placeholderFractions[ws.id.rawValue.utf8.reduce(0) { $0 &+ Int($1) } % SidebarStyle.placeholderFractions.count]
        // SIDEBAR-ROWS-MINIMAL-AND-CUSTOMIZABLE: the row draws only what its
        // content (`WorkspaceRowContent`) says. WORKSPACE-ROWS-NO-DEFAULT-ICON:
        // only a user's icon draws; without one the title takes the place.
        let shown = row.content ?? WorkspaceRowContent()
        icon.configure(icon: shown.icon)
        iconKind = shown.icon
        title.stringValue = ws.title
        title.font = ws.unread.isUnread ? SidebarStyle.titleUnreadFont : SidebarStyle.titleFont
        subtitle.font = SidebarStyle.subtitleFont
        subtitle.stringValue = row.detail ?? ""
        hasSubtitle = row.detail != nil
        activity.configure(shown.activity, style: ws.activityStyle)
        activityState = shown.activity
        agentMarkVariant = content.agentMark
        let markImage = agentMarkVariant == .off || isShowingPlaceholder ? nil
            : ws.agentBrand.flatMap { AgentBrandCatalog.templateImage(brand: $0, size: SidebarStyle.indicatorSize) }
        agentMark.image = markImage
        agentMark.isHidden = markImage == nil
        badge.configure(ws.unread)
        let config = NSImage.SymbolConfiguration(pointSize: SidebarStyle.indicatorSize - Metrics.space1, weight: .regular)
        mutedMark.image = ws.muted && !isShowingPlaceholder
            ? NSImage(systemSymbolName: "bell.slash", accessibilityDescription: nil)?.withSymbolConfiguration(config) : nil
        mutedMark.isHidden = mutedMark.image == nil
        disclosure = row.tabDisclosure
        count = row.tabCount
        disclosureButton.symbol = row.tabDisclosure == .expanded ? "chevron.down" : "chevron.right"
        disclosureButton.label = row.tabDisclosure == .expanded ? Strings.hideTabs : Strings.showTabs
        disclosureButton.setAccessibilityExpanded(row.tabDisclosure == .expanded)
        tabCount.stringValue = row.tabCount.map(String.init) ?? ""
        badgeText = shown.badge
        prBadge.stringValue = shown.badge ?? ""
        progress = shown.progress
        // The workspace hover card shows the cwd (and CPU and memory).
        toolTip = nil
        // A placeholder says nothing; its section header says it connects.
        setAccessibilityElement(!isShowingPlaceholder)
        setAccessibilityRole(.row)
        setAccessibilityIdentifier("cmux.sidebar.workspace.\(ws.id.rawValue)")
        setAccessibilityLabel(accessibilityText(ws, content: shown))
        needsLayout = true
        needsDisplay = true
    }

    private func accessibilityText(_ ws: SidebarWorkspace, content: WorkspaceRowContent) -> String {
        var parts = [ws.title]
        if let s = content.detail { parts.append(s) }
        if let s = content.badge { parts.append(s) }
        if let value = content.progress?.value { parts.append(Strings.progressPercent(Int((value * 100).rounded()))) }
        if let count { parts.append(Strings.tabCount(count)) }
        switch ws.unread {
        case let .count(n) where n > 0: parts.append(Strings.unreadCount(n))
        case .dot: parts.append(Strings.unreadDot)
        default: break
        }
        if let text = Strings.activity(content.activity) { parts.append(text) }
        if ws.muted { parts.append(Strings.muted) }
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
    /// Room for a two-digit count, so 9 to 10 tabs moves nothing else.
    static let countWidth: CGFloat = 18
    /// The PR badge never takes more than this from the title.
    static let badgeMaxWidth: CGFloat = 72

    override func hoverChanged() {
        super.hoverChanged()
        needsLayout = true
        guard isHovered, !renaming, !isShowingPlaceholder else {
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
        performWithTheme {
            title.textColor = Palette.textPrimary
            subtitle.textColor = Palette.textSecondary
            tabCount.textColor = Palette.textTertiary
            mutedMark.contentTintColor = Palette.textTertiary
            prBadge.textColor = Palette.textSecondary
            agentMark.contentTintColor = activityState == .waiting ? Palette.attention : Palette.textSecondary
            // Fills only, no borders: drop target, selection, multi-selection, hover.
            paintFill(isDropTarget || isSelected ? Palette.selectionFill
                : isSecondarySelected ? Palette.secondarySelectionFill
                : isHovered && !isShowingPlaceholder ? Palette.hoverFill : nil)
            // The sidebar's own tonal step, once more: a bar a step apart.
            placeholderBar.layer?.backgroundColor = Palette.sidebarStep.cgColor
        }
    }

    override func layout() {
        super.layout()
        let b = layoutBounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        // The members' bar (cx-rcby, the Chrome tab group line): one thin
        // line in the group's theme color under the chip's rounded start,
        // through every member row (full height, so rows join) and rounded
        // off under the last member; a neutral line for a group without a color.
        let indent: CGFloat = grouped ? SidebarStyle.groupMemberIndent : 0
        let barWidth = SidebarStyle.groupBarWidth
        let barBottom = lastInGroup ? Metrics.space2 : 0
        groupRail.frame = NSRect(x: SidebarStyle.groupBarX, y: 0, width: barWidth, height: max(0, b.height - barBottom))
        groupRail.isHidden = !grouped
        performWithTheme {
            groupRail.backgroundColor = (groupColor?.themed ?? Palette.textTertiary.withAlphaComponent(0.5)).cgColor
            groupRail.cornerRadius = lastInGroup ? barWidth / 2 : 0
            groupRail.maskedCorners = isFlipped ? [.layerMinXMaxYCorner, .layerMaxXMaxYCorner] : [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        }
        // A custom workspace icon takes the leading slot; without one the
        // title starts at the leading inset (no default kind glyph).
        let leading = SidebarStyle.horizontalInset + indent
        let side: CGFloat
        switch iconKind {
        case nil: side = 0
        case .swatch?: side = SidebarStyle.dotSize + Metrics.space1
        case .symbol?, .emoji?: side = SidebarStyle.iconBox
        }
        icon.frame = NSRect(x: leading, y: (b.height - side) / 2, width: side, height: side)

        // Trailing cluster, right to left: the disclosure and the tab count
        // (fixed slots, the same with or without hover), close-or-badge, then
        // activity.
        var trailing = b.width - Metrics.space3
        let control = SidebarStyle.controlSize
        disclosureButton.isHidden = disclosure == nil || disclosure == .empty || isShowingPlaceholder
        if disclosure != nil {
            disclosureButton.frame = NSRect(x: trailing - control, y: (b.height - control) / 2, width: control, height: control)
            trailing -= control + Metrics.space1
        }
        tabCount.isHidden = count == nil || isShowingPlaceholder
        if count != nil {
            let h = ceil(tabCount.intrinsicContentSize.height)
            tabCount.frame = NSRect(x: trailing - Self.countWidth, y: (b.height - h) / 2, width: Self.countWidth, height: h)
            trailing -= Self.countWidth + Metrics.space2
        }
        prBadge.isHidden = badgeText == nil || isShowingPlaceholder
        if badgeText != nil {
            let size = prBadge.intrinsicContentSize
            let w = min(ceil(size.width), Self.badgeMaxWidth), h = ceil(size.height)
            prBadge.frame = NSRect(x: trailing - w, y: (b.height - h) / 2, width: w, height: h)
            trailing -= w + Metrics.space2
        }
        // The x and an unread badge share one slot, as wide as the wider of
        // the two, so hover swaps them in place and the name keeps its width.
        let showClose = isHovered && !isShowingPlaceholder && isClosable
        closeButton.isHidden = !showClose
        badge.isHidden = showClose || !badge.state.isUnread
        var slot: CGFloat = showClose ? control : 0
        if badge.state.isUnread {
            let w = badge.preferredWidth
            let h = badge.state == .dot ? SidebarStyle.dotSize : SidebarStyle.badgeHeight
            let pad = badge.state == .dot ? Metrics.space2 : 0
            badge.frame = NSRect(x: trailing - w - pad, y: (b.height - h) / 2, width: w, height: h)
            slot = max(control, w + pad)
        }
        if showClose {
            closeButton.frame = NSRect(x: trailing - control, y: (b.height - control) / 2, width: control, height: control)
        }
        if slot > 0 { trailing -= slot + Metrics.space2 }
        let ind = SidebarStyle.indicatorSize
        let markReplacesStatus = !agentMark.isHidden && agentMarkVariant == .replacesStatus
        activity.isHidden = markReplacesStatus
        if markReplacesStatus {
            agentMark.frame = NSRect(x: trailing - ind, y: (b.height - ind) / 2, width: ind, height: ind)
            trailing -= ind + Metrics.space2
        } else if activity.showsGlyph {
            activity.frame = NSRect(x: trailing - ind, y: (b.height - ind) / 2, width: ind, height: ind)
            trailing -= ind + Metrics.space2
        }
        if !mutedMark.isHidden {
            mutedMark.frame = NSRect(x: trailing - ind, y: (b.height - ind) / 2, width: ind, height: ind)
            trailing -= ind + Metrics.space2
        }

        var textX = side > 0 ? icon.frame.maxX + Metrics.space3 : leading
        if !agentMark.isHidden && agentMarkVariant == .besideTitle {
            agentMark.frame = NSRect(x: textX + Self.labelInset, y: (b.height - ind) / 2, width: ind, height: ind)
            textX = agentMark.frame.maxX + Metrics.space1
        }
        let textW = max(0, trailing - textX)
        title.isHidden = renaming || isShowingPlaceholder
        placeholderBar.isHidden = !isShowingPlaceholder
        let barHeight = SidebarStyle.placeholderBarHeight
        placeholderBar.frame = NSRect(x: textX + Self.labelInset, y: (b.height - barHeight) / 2,
                                      width: max(0, textW - 2 * Self.labelInset) * placeholderFraction, height: barHeight)
        // The marquee fades glyphs out across the padding left of them.
        let inset = Self.labelInset
        title.leadingPadding = textX + inset - (side > 0 ? icon.frame.maxX : indent)
        title.fadeWidth = SidebarStyle.titleFadeWidth
        let th = ceil(title.intrinsicContentSize.height)
        let titleWidth = max(0, textW - 2 * inset)
        if hasSubtitle {
            let sh = ceil(subtitle.intrinsicContentSize.height)
            let total = th + Metrics.space1 + sh
            let top = (b.height - total) / 2
            title.frame = NSRect(x: textX + inset, y: top, width: titleWidth, height: th)
            subtitle.frame = NSRect(x: textX, y: top + th + Metrics.space1, width: textW, height: sh)
            subtitle.isHidden = false
        } else {
            title.frame = NSRect(x: textX + inset, y: (b.height - th) / 2, width: titleWidth, height: th)
            subtitle.isHidden = true
        }
        layoutProgress(x: textX, width: max(0, b.width - Metrics.space3 - textX), bottom: b.maxY)
        needsDisplay = true
    }

    private func layoutProgress(x: CGFloat, width: CGFloat, bottom: CGFloat) {
        guard let progress else {
            progressTrack.isHidden = true
            return
        }
        let height: CGFloat = 2
        progressTrack.isHidden = false
        progressTrack.frame = CGRect(x: x, y: isFlipped ? bottom - height - 1 : 1, width: width, height: height)
        progressTrack.cornerRadius = height / 2
        progressFill.frame = CGRect(x: 0, y: 0, width: width * (progress.value ?? 1), height: height)
        progressFill.cornerRadius = height / 2
        performWithTheme {
            progressTrack.backgroundColor = Palette.textTertiary.withAlphaComponent(0.25).cgColor
            let color = progress.isError ? Palette.danger : Palette.accent
            progressFill.backgroundColor = (progress.value == nil ? color.withAlphaComponent(0.4) : color).cgColor
        }
    }
}

// MARK: - Group header
