import AppKit
import Observation
import CmuxAgentBrands
import CmuxNextDesign
import CmuxNextIcons
import QuartzCore

final class WorkspaceRowView: SidebarRowView {
    let icon = SidebarIconView()
    /// Fades a clipped title and scrolls it while the pointer rests on the
    /// row (TitleFade); NSTextField would end it in an ellipsis instead.
    let title = MarqueeLabel()
    let subtitle = SidebarRowView.label(font: SidebarStyle.subtitleFont)
    /// Expanded rows (`sidebar.density`, cx-13w3; WorkspaceRowView+Expanded): the age and the meta line.
    let timeLabel = SidebarRowView.label(font: SidebarStyle.subtitleFont), metaLabel = SidebarRowView.label(font: SidebarStyle.subtitleFont)
    private let activity = StatusIndicatorView()
    /// The running agent's brand mark (`SidebarAgentMarkVariant`); hidden when off.
    private let agentMark = NSImageView()
    private var agentMarkVariant = SidebarAgentMarkVariant.off
    /// The last configuration, so a Debug Settings switch of `sidebar.agentMark` redraws the row.
    private var lastConfiguration: (SidebarWorkspace, SidebarRow)?
    private var activityState = StatusIndicatorState.idle
    private let badge = UnreadBadgeView()
    /// The agents acting in the workspace (`sidebar.presenceDots`, cx-gg84).
    let presenceDots = PresenceDotsView()
    /// A muted workspace (`notifications.mutedWorkspaces`): a quiet bell-slash
    /// in the trailing cluster, in the tertiary text color; hidden otherwise.
    let mutedMark = NSImageView()
    let closeButton = SidebarIconButton(icon: .actionClose, pointSize: { Metrics.smallIconSize - Metrics.space2 }, label: Strings.closeButton)
    /// The row's menu (cx-a9h6, ChatGPT project style): the right-click menu,
    /// under the button. Shows on hover only, over the end of the title
    /// behind a fade (Lawrence 2026-10-11: no layout shift).
    let moreButton = SidebarIconButton(icon: .actionMore, pointSize: { Metrics.smallIconSize - Metrics.space1 },
                                       label: Strings.workspaceMenu)
    /// An expanded row's Pin or Unpin (cx-13w3), on hover beside the menu button.
    let pinButton = SidebarIconButton(icon: .actionPin, pointSize: { Metrics.smallIconSize - Metrics.space2 }, label: Strings.pinWorkspace)
    /// `sidebar.showWorkspaceTabs`: hides or lists the workspace's tabs. Always drawn
    /// while the setting is on (never on hover), so rows never shift.
    let disclosureButton = SidebarIconButton(icon: .disclosureCollapsed, pointSize: { Metrics.smallIconSize - Metrics.space2 },
                                             label: Strings.showTabs)
    /// `sidebar.workspaceRow.tabCount`: the workspace's tab count, in a fixed-width slot.
    private let tabCount = SidebarRowView.label(font: SidebarStyle.subtitleFont)
    /// `sidebar.workspaceRow.pullRequest`: the PR / CI badge a hook reported.
    private let prBadge = SidebarRowView.label(font: SidebarStyle.subtitleFont)
    private var badgeText: String?
    private(set) var disclosure: SidebarTabDisclosure?
    private(set) var count: Int?

    /// Progress under the row (`SidebarWorkspace.progress`): a track and a
    /// fill; an indeterminate one fills the whole track, dimmed.
    let progressTrack = CALayer()
    let progressFill = CALayer()
    private(set) var progress: SidebarProgress?
    /// Classic's status block under the name (`WorkspaceRowContent.status`).
    let statusBlock = WorkspaceStatusView()
    private(set) var statusHeight: CGFloat = 0
    var hasSubtitle = false, isExpanded = false, timeText: String?
    private var grouped = false
    private var iconKind: WorkspaceIcon?
    /// Selected but not active (the active row paints the selection fill).
    var isSecondarySelected = false { didSet { if isSecondarySelected != oldValue { needsDisplay = true } } }
    /// A tab dragged from a pane would move into this workspace.
    var isDropTarget = false { didSet { if isDropTarget != oldValue { needsDisplay = true } } }
    var onClose: (() -> Void)?
    var onMore: (() -> Void)?
    /// nil: the App offers no pin; the pin button does not show.
    var onPin: (() -> Void)?, isPinned: (() -> Bool?)?
    /// Activates this workspace from an accessibility AXPress.
    var onSelect: (() -> Void)?
    var onToggleTabs: (() -> Void)?
    /// The row draws a placeholder bar instead of a title.
    private(set) var isShowingPlaceholder = false
    /// Any placeholder, titled or not: no hover fill, no marquee, no press (cx-gaq9).
    private var isPlaceholderRow = false
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
        [icon, title, subtitle, timeLabel, metaLabel, activity, agentMark, mutedMark, badge, presenceDots, closeButton, moreButton, pinButton, disclosureButton, tabCount, prBadge, placeholderBar, statusBlock]
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
        closeButton.isHidden = true
        placeholderBar.wantsLayer = true
        placeholderBar.layer?.cornerRadius = Metrics.chipCornerRadius(height: SidebarStyle.placeholderBarHeight)
        placeholderBar.isHidden = true
        closeButton.onPress = { [weak self] in self?.onClose?() }
        moreButton.onPress = { [weak self] in self?.onMore?() }
        pinButton.onPress = { [weak self] in self?.onPin?() }
        disclosureButton.onPress = { [weak self] in self?.onToggleTabs?() }
    }

    override var interactiveSubviews: [NSView] { [closeButton, moreButton, pinButton, disclosureButton] }
    override var debugDisclosure: (icon: String, frame: CGRect, shown: Bool)? {
        disclosure == nil ? nil : (disclosureButton.icon.rawValue, disclosureButton.frame, !disclosureButton.isHidden)
    }

    /// Reads the agent mark and presence dot settings and redraws the row once when one changes (no polling).
    private func observedTunables() -> (agentMark: SidebarAgentMarkVariant, presenceDots: Bool) {
        withObservationTracking {
            (SidebarTunables.agentMark.value, SidebarTunables.presenceDots.value)
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
        onMore = nil
        (onPin, isPinned) = (nil, nil)
        onSelect = nil
        onToggleTabs = nil
        title.stopMarquee()
    }

    private struct Content: Hashable {
        var ws: SidebarWorkspace
        var group: GroupID?
        var fontSize: CGFloat
        var iconSize: CGFloat
        var agentMark: SidebarAgentMarkVariant
        var presenceDots: Bool
        var disclosure: SidebarTabDisclosure?
        var row: WorkspaceRowContent?
    }

    func configure(_ ws: SidebarWorkspace, row: SidebarRow) {
        lastConfiguration = (ws, row)
        let tunables = observedTunables()
        let content = Content(
            ws: ws, group: row.group,
            fontSize: SidebarStyle.titleFont.pointSize, iconSize: Metrics.smallIconSize,
            agentMark: tunables.agentMark, presenceDots: tunables.presenceDots,
            disclosure: row.tabDisclosure, row: row.content
        )
        guard needsConfigure(content) else { return }
        grouped = row.group != nil
        // A placeholder with a title (a connecting SSH machine, cx-gaq9) draws its text, not the bar.
        isShowingPlaceholder = ws.rowState == .placeholder && ws.title.isEmpty
        isPlaceholderRow = ws.rowState == .placeholder
        isClosable = ws.isClosable
        placeholderFraction = SidebarStyle.placeholderFractions[ws.id.rawValue.utf8.reduce(0) { $0 &+ Int($1) } % SidebarStyle.placeholderFractions.count]
        // SIDEBAR-ROWS-MINIMAL-AND-CUSTOMIZABLE: the row draws only what its
        // content (`WorkspaceRowContent`) says. WORKSPACE-ROWS-NO-DEFAULT-ICON:
        // only a user's icon or a page's favicon draws; else the title leads.
        let shown = row.content ?? WorkspaceRowContent()
        icon.configure(icon: shown.icon)
        iconKind = shown.icon
        title.stringValue = ws.title
        title.font = ws.unread.isUnread ? SidebarStyle.titleUnreadFont : SidebarStyle.titleFont
        subtitle.font = SidebarStyle.subtitleFont
        subtitle.stringValue = row.detail ?? ""
        hasSubtitle = row.detail != nil
        (isExpanded, timeText, timeLabel.stringValue, metaLabel.stringValue) = (shown.expanded, shown.time, shown.time ?? "", shown.meta ?? "")
        activity.configure(shown.activity, style: ws.activityStyle)
        activityState = shown.activity
        agentMarkVariant = content.agentMark
        let markImage = agentMarkVariant == .off || isShowingPlaceholder ? nil
            : ws.agentBrand.flatMap { AgentBrandCatalog.templateImage(brand: $0, size: SidebarStyle.indicatorSize) }
        agentMark.image = markImage
        agentMark.isHidden = markImage == nil
        badge.configure(ws.unread)
        presenceDots.configure(content.presenceDots && !isShowingPlaceholder ? ws.presence : [])
        mutedMark.image = ws.muted && !isShowingPlaceholder
            ? NSImage.icon(symbol: "bell.slash", size: .iconRowSize(forLabelPointSize: SidebarStyle.indicatorSize - Metrics.space1)) : nil
        mutedMark.isHidden = mutedMark.image == nil
        disclosure = row.tabDisclosure
        count = row.tabCount
        disclosureButton.icon = row.tabDisclosure == .expanded ? .disclosureExpanded : .disclosureCollapsed
        disclosureButton.label = row.tabDisclosure == .expanded ? Strings.hideTabs : Strings.showTabs
        disclosureButton.setAccessibilityExpanded(row.tabDisclosure == .expanded)
        tabCount.stringValue = row.tabCount.map(String.init) ?? ""
        badgeText = shown.badge
        prBadge.stringValue = shown.badge ?? ""
        progress = shown.progress
        statusBlock.isHidden = shown.status == nil || isShowingPlaceholder
        statusBlock.configure(shown.status ?? SidebarWorkspaceStatus(), reservesBar: shown.progress != nil)
        statusHeight = statusBlock.isHidden ? 0 : SidebarLayoutMetrics.standard.statusHeight(shown)
        // The workspace hover card shows the cwd (and CPU and memory).
        themedToolTip = nil
        // A placeholder says nothing; its section header says it connects.
        setAccessibilityElement(!isShowingPlaceholder)
        setAccessibilityRole(.row)
        setAccessibilityIdentifier("cmux.sidebar.workspace.\(ws.id.rawValue)")
        setAccessibilityLabel(accessibilityText(ws, content: shown))
        needsLayout = true
        needsDisplay = true
    }

    /// Where an NSTextField label with this text would sit (inline rename
    /// aligns its field to it): the glyphs start one cell inset inside it.
    override var titleFrame: NSRect { title.frame.insetBy(dx: -Self.labelInset, dy: 0) }
    override var titleFont: NSFont { title.font }
    private var renaming = false
    override func setTitleHidden(_ hidden: Bool) {
        renaming = hidden
        title.isHidden = hidden
        needsLayout = true
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
        guard isHovered, !renaming, !isPlaceholderRow else {
            title.stopMarquee()
            return
        }
        // The x and the more button draw over the title's end behind a fade,
        // so the title keeps its width; a clipped title scrolls. Under Reduce
        // Motion no marquee runs: the workspace hover card shows the whole
        // name (wrapped), so no second popover (a tooltip) shows with it.
        layoutSubtreeIfNeeded()
        title.startMarquee()
    }

    override func updateLayer() {
        performWithTheme {
            title.textColor = Palette.textPrimary
            subtitle.textColor = Palette.textSecondary; [timeLabel, metaLabel].forEach { $0.textColor = Palette.textTertiary }
            tabCount.textColor = Palette.textTertiary
            mutedMark.contentTintColor = Palette.textTertiary
            prBadge.textColor = Palette.textSecondary
            let waits = if case .waiting = activityState { true } else { false }
            agentMark.contentTintColor = waits ? Palette.attention : Palette.textSecondary
            // Fills only, no borders: drop target, selection, multi-selection, hover.
            paintFill(isDropTarget || isSelected ? Palette.selectionFill
                : isSecondarySelected ? Palette.secondarySelectionFill
                : isHovered && !isPlaceholderRow ? Palette.hoverFill : nil)
            // The sidebar's own tonal step, once more: a bar a step apart.
            placeholderBar.layer?.backgroundColor = Palette.sidebarStep.cgColor
        }
    }

    override func layout() {
        super.layout()
        let full = layoutBounds
        // The name lines and the trailing cluster center in the head; the
        // status block, when shown, fills the rest below it.
        let b = NSRect(x: full.minX, y: full.minY, width: full.width, height: full.height - statusHeight)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let fades = fadesNextHover
        defer { fadesNextHover = false; CATransaction.commit() }

        // Members indent under their group header; the members' line is
        // one layer per group under the rows (SidebarListView+GroupLines).
        let indent: CGFloat = grouped ? SidebarStyle.groupMemberIndent : 0
        let (th, sh, top, cy) = textMetrics(head: b)
        // A custom workspace icon takes the leading slot; without one the
        // title starts at the leading inset (no default kind glyph).
        let leading = SidebarStyle.horizontalInset + indent
        let side: CGFloat
        switch iconKind {
        case nil: side = 0
        case .swatch?: side = SidebarStyle.dotSize + Metrics.space1
        case .symbol?, .emoji?, .favicon?: side = SidebarStyle.iconBox
        }
        icon.frame = NSRect(x: leading, y: cy - side / 2, width: side, height: side)

        // Trailing cluster, right to left: the disclosure and the tab count
        // (fixed slots, the same with or without hover), close-or-badge, then
        // activity.
        var trailing = b.width - SidebarStyle.horizontalInset // the pill's own inset, as the text's (Leo 2026-10-13)
        let control = SidebarStyle.controlSize
        // The chevron shows on hover and on the selected row only (cx-fo2t); its slot stays.
        setHoverShown(disclosureButton, !(disclosure == nil || disclosure == .empty || isShowingPlaceholder || !(isHovered || isSelected)), fades: fades)
        if disclosure != nil {
            disclosureButton.frame = NSRect(x: trailing - control, y: cy - control / 2, width: control, height: control)
            trailing -= control + Metrics.space1
        }
        tabCount.isHidden = count == nil || isShowingPlaceholder
        if count != nil {
            let h = ceil(tabCount.intrinsicContentSize.height)
            tabCount.frame = NSRect(x: trailing - Self.countWidth, y: cy - h / 2, width: Self.countWidth, height: h)
            trailing -= Self.countWidth + Metrics.space2
        }
        prBadge.isHidden = badgeText == nil || isShowingPlaceholder
        if badgeText != nil {
            let size = prBadge.intrinsicContentSize
            let w = min(ceil(size.width), Self.badgeMaxWidth), h = ceil(size.height)
            prBadge.frame = NSRect(x: trailing - w, y: cy - h / 2, width: w, height: h)
            trailing -= w + Metrics.space2
        }
        // Lawrence 2026-10-11 ("Overlay with fade"): the title keeps its full
        // width at rest and on hover. The x and the more button draw over the
        // end of the title, which fades out before them (an alpha mask), so
        // nothing moves. Marks under them hide while they show. An unread
        // badge keeps its slot at rest, and the action that lands there on
        // hover hides it.
        let showClose = isHovered && !isShowingPlaceholder && isClosable
        let showMore = !isPlaceholderRow && onMore != nil && isHovered && !renaming
        setHoverShown(closeButton, showClose, fades: fades)
        setHoverShown(badge, !(showClose || (showMore && !isClosable) || !badge.state.isUnread), fades: fades)
        var slot: CGFloat = 0
        if badge.state.isUnread {
            let w = badge.preferredWidth
            let h = badge.state == .dot ? SidebarStyle.dotSize : SidebarStyle.badgeHeight
            let pad = badge.state == .dot ? Metrics.space2 : 0
            badge.frame = NSRect(x: trailing - w - pad, y: cy - h / 2, width: w, height: h)
            slot = max(control, w + pad)
        }
        closeButton.frame = NSRect(x: trailing - control, y: cy - control / 2, width: control, height: control)
        if slot > 0 { trailing -= slot + Metrics.space2 }
        trailing = layoutTime(trailing: trailing, cy: cy, height: sh)
        // The menu button, on hover only, left of the x (or in its place on a
        // row that cannot close). Hidden (not only clear) when it does not
        // show; VoiceOver uses the row's custom action.
        setHoverShown(moreButton, showMore, fades: fades)
        moreButton.frame = closeButton.frame.offsetBy(dx: isClosable && !isShowingPlaceholder ? -(control + Metrics.space1) : 0, dy: 0)
        let pinStart = layoutPin(showMore: showMore, control: control, fades: fades)
        let overlayStart = [showClose ? closeButton.frame.minX : nil, showMore ? moreButton.frame.minX : nil, pinStart].compactMap { $0 }.min()
        let ind = SidebarStyle.indicatorSize
        let markReplacesStatus = !agentMark.isHidden && agentMarkVariant == .replacesStatus
        activity.isHidden = markReplacesStatus
        if markReplacesStatus {
            agentMark.frame = NSRect(x: trailing - ind, y: cy - ind / 2, width: ind, height: ind)
            trailing -= ind + Metrics.space2
        } else if activity.showsGlyph {
            activity.frame = NSRect(x: trailing - ind, y: cy - ind / 2, width: ind, height: ind)
            trailing -= ind + Metrics.space2
        }
        if !mutedMark.isHidden {
            mutedMark.frame = NSRect(x: trailing - ind, y: cy - ind / 2, width: ind, height: ind)
            trailing -= ind + Metrics.space2
        }
        if !presenceDots.isHidden {
            let w = presenceDots.preferredWidth
            presenceDots.frame = NSRect(x: trailing - w, y: isExpanded ? top : 0, width: w, height: isExpanded ? th : b.height)
            trailing -= w + Metrics.space2
        }

        var textX = side > 0 ? icon.frame.maxX + Metrics.space3 : leading - Self.labelInset // the title's text starts at `leading`
        if !agentMark.isHidden && agentMarkVariant == .besideTitle {
            agentMark.frame = NSRect(x: textX + Self.labelInset, y: cy - ind / 2, width: ind, height: ind)
            textX = agentMark.frame.maxX + Metrics.space1
        }
        let textW = max(0, trailing - textX)
        title.isHidden = renaming || isShowingPlaceholder
        placeholderBar.isHidden = !isShowingPlaceholder
        let barHeight = SidebarStyle.placeholderBarHeight
        placeholderBar.frame = NSRect(x: textX + Self.labelInset, y: cy - barHeight / 2,
                                      width: max(0, textW - 2 * Self.labelInset) * placeholderFraction, height: barHeight)
        // The marquee fades glyphs out across the padding left of them.
        let inset = Self.labelInset
        title.leadingPadding = textX + inset - (side > 0 ? icon.frame.maxX : indent)
        title.fadeWidth = SidebarStyle.titleFadeWidth
        let titleWidth = max(0, textW - inset) // draws at its edge, so it runs to `trailing`
        layoutTextLines(x: textX, inset: inset, titleWidth: titleWidth, width: textW, head: b, top: top, title: th, line: sh)
        // The hover actions draw over the text's end: the title and second
        // line fade out before them (alpha masks, every backdrop), and the
        // marks they cover hide while they show.
        let fade = SidebarStyle.titleFadeWidth
        title.setTrailingOcclusion(overlayStart.map { max(0, title.frame.maxX - ($0 - Metrics.space1)) } ?? 0, animated: fades)
        subtitle.wantsLayer = true
        subtitle.setTrailingFade(occlusion: overlayStart.map { max(0, subtitle.frame.maxX - ($0 - Metrics.space1)) } ?? 0, fade: fade, animated: fades)
        for mark in [activity, agentMark, mutedMark, presenceDots, timeLabel] as [NSView] {
            fadeOpacity(mark, to: overlayStart.map { mark.frame.maxX > $0 - Metrics.space1 } == true ? 0 : 1, fades: fades)
        }
        layoutStatus(x: textX, width: max(0, b.width - Metrics.space3 - textX), head: b.maxY, bottom: full.maxY)
        needsDisplay = true
    }
}

// MARK: - Group header
