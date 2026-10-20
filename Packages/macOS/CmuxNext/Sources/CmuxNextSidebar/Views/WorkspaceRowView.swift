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
    let activity = StatusIndicatorView()
    /// The running agent's brand mark (`SidebarAgentMarkVariant`); hidden when off.
    internal let agentMark = NSImageView()
    internal(set) var agentMarkVariant = SidebarAgentMarkVariant.off
    /// The last configuration, so a Debug Settings switch of `sidebar.agentMark` redraws the row.
    internal(set) var lastConfiguration: (SidebarWorkspace, SidebarRow, SidebarRowBadgeStyle?)?
    var activityState = StatusIndicatorState.idle
    let badge = UnreadBadgeView(), rowBadge = RowBadgeView() // the count, and its replacement (WorkspaceRowView+Badges)
    var rowBadgeStyle = SidebarRowBadgeStyle.corner
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
    let tabCount = SidebarRowView.label(font: SidebarStyle.subtitleFont)
    /// `sidebar.workspaceRow.pullRequest`: the PR / CI badge a hook reported.
    let prBadge = SidebarRowView.label(font: SidebarStyle.subtitleFont)
    var badgeText: String?
    internal(set) var disclosure: SidebarTabDisclosure?
    internal(set) var count: Int?

    /// Progress under the row (`SidebarWorkspace.progress`): a track and a
    /// fill; an indeterminate one fills the whole track, dimmed.
    let progressTrack = CALayer()
    let progressFill = CALayer()
    internal(set) var progress: SidebarProgress?
    /// Classic's status block under the name (`WorkspaceRowContent.status`).
    let statusBlock = WorkspaceStatusView()
    internal(set) var statusHeight: CGFloat = 0
    var hasSubtitle = false, isExpanded = false, timeText: String?
    var grouped = false
    var iconKind: WorkspaceIcon?
    /// Selected but not active (the active row paints the selection fill).
    var isSecondarySelected = false {
        didSet {
            guard isSecondarySelected != oldValue else { return }
            updateAccessibilitySelection()
            needsDisplay = true
        }
    }
    override var showsSelection: Bool { isSelected || isSecondarySelected }
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
    internal(set) var isShowingPlaceholder = false
    /// Any placeholder, titled or not: no hover fill, no marquee, no press (cx-gaq9).
    var isPlaceholderRow = false
    /// The row's workspace can close (`SidebarWorkspace.isClosable`); the
    /// home row shows no close button.
    internal(set) var isClosable = true
    /// A static tonal bar where the title goes (no shimmer).
    let placeholderBar = NSView()
    /// The bar's share of the text width, varied per row so a column of
    /// placeholders does not read as one block.
    var placeholderFraction: CGFloat = 0.6
    /// The last title painted by this view. Recycled rows clear this so a
    /// different workspace never inherits a title transition.
    internal var lastTitle: String?
    /// A placeholder row can become a titled row after the daemon reports it.
    /// Keep both layers alive until the first post-layout frame so the loading
    /// bar can fade away as the title arrives instead of disappearing first.
    var titleArrivalPending = false
    var titleArrivalScheduled = false
    var titleArrivalActive = false
    internal var titleArrivalGeneration: UInt = 0
    internal var titleArrivalVariant = SidebarWorkspaceTitleMotionVariant.instant

    required init(key: SidebarRowKey) {
        super.init(key: key)
        title.font = SidebarStyle.titleFont
        agentMark.imageScaling = .scaleProportionallyDown
        agentMark.isHidden = true
        mutedMark.imageScaling = .scaleProportionallyDown
        mutedMark.isHidden = true
        mutedMark.setAccessibilityElement(false)
        [icon, title, subtitle, timeLabel, metaLabel, activity, agentMark, mutedMark, badge, rowBadge, presenceDots, closeButton, moreButton, pinButton, disclosureButton, tabCount, prBadge, placeholderBar, statusBlock]
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
        title.wantsLayer = true
        closeButton.onPress = { [weak self] in self?.onClose?() }
        moreButton.onPress = { [weak self] in self?.onMore?() }
        pinButton.onPress = { [weak self] in self?.onPin?() }
        disclosureButton.onPress = { [weak self] in self?.onToggleTabs?() }
    }

    override var interactiveSubviews: [NSView] { [closeButton, moreButton, pinButton, disclosureButton] }
    override var debugIcon: String? {
        switch iconKind {
        case nil: !agentMark.isHidden && agentMarkVariant == .besideTitle ? "agentMark" : nil
        case .symbol?: "symbol"
        case .swatch?: "swatch"
        case .emoji?: "emoji"
        case .favicon?: "favicon"
        }
    }
    override var debugDisclosure: (icon: String, frame: CGRect, shown: Bool)? {
        disclosure == nil ? nil : (disclosureButton.icon.rawValue, disclosureButton.frame, !disclosureButton.isHidden)
    }

    /// Draws the last configuration again (a sidebar tunable changed).
    func redrawLastConfiguration() {
        guard let last = lastConfiguration else { return }
        configure(last.0, row: last.1, badgeStyle: last.2)
    }

    /// Its configure sets everything the reset clears again, or the list does (hover, selection, callbacks).
    override class var keepsContentOnReturn: Bool { true }

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
        title.layer?.removeAnimation(forKey: "workspace-title-motion")
        lastTitle = nil
        titleArrivalGeneration &+= 1
        titleArrivalPending = false
        titleArrivalScheduled = false
        titleArrivalActive = false
        title.alphaValue = 1
        placeholderBar.layer?.removeAllAnimations()
        placeholderBar.alphaValue = 1
    }

    private struct Content: Hashable {
        var ws: SidebarWorkspace
        var group: GroupID?
        var fontSize: CGFloat
        var iconSize: CGFloat
        var agentMark: SidebarAgentMarkVariant, presenceDots: Bool, rowBadge: SidebarRowBadgeStyle, stackLimit: Int
        var disclosure: SidebarTabDisclosure?
        var row: WorkspaceRowContent?
    }

    func configure(_ ws: SidebarWorkspace, row: SidebarRow, badgeStyle: SidebarRowBadgeStyle? = nil) {
        lastConfiguration = (ws, row, badgeStyle)
        let tunables = observedTunables()
        let content = Content(
            ws: ws, group: row.group,
            fontSize: SidebarStyle.titleFont.pointSize, iconSize: Metrics.smallIconSize,
            agentMark: tunables.agentMark, presenceDots: tunables.presenceDots, rowBadge: badgeStyle ?? tunables.rowBadge, stackLimit: tunables.stackCap.limit,
            disclosure: row.tabDisclosure, row: row.content
        )
        guard needsConfigure(content) else { return }
        grouped = row.group != nil
        // A placeholder with a title (a connecting SSH machine, cx-gaq9) draws its text, not the bar.
        isShowingPlaceholder = ws.rowState == .placeholder && ws.title.isEmpty
        isPlaceholderRow = ws.rowState.isPending
        isClosable = ws.isClosable
        placeholderFraction = SidebarStyle.placeholderFractions[ws.id.rawValue.utf8.reduce(0) { $0 &+ Int($1) } % SidebarStyle.placeholderFractions.count]
        // SIDEBAR-ROWS-MINIMAL-AND-CUSTOMIZABLE: the row draws only what its
        // content (`WorkspaceRowContent`) says. WORKSPACE-ROWS-NO-DEFAULT-ICON:
        // only a user's icon or a page's favicon draws; else the title leads.
        let shown = row.content ?? WorkspaceRowContent()
        // A row badge style other than `.trailing` draws the unread count and activity in its
        // badge (`configureBadges`): set those views once, here, so a status tick does not flip
        // the activity indicator twice per configure. The badge never brings a kind glyph or an
        // agent brand with it: a row without the user's icon or a favicon stays text only, and
        // its corner badge sits in the trailing slot (`layoutRowBadge`).
        let badgesLead = content.rowBadge != .trailing && !isShowingPlaceholder
        icon.configure(icon: shown.icon)
        iconKind = shown.icon
        let priorTitle = lastTitle
        if titleArrivalPending || titleArrivalScheduled || titleArrivalActive {
            titleArrivalGeneration &+= 1
            titleArrivalPending = false
            titleArrivalScheduled = false
            titleArrivalActive = false
            title.alphaValue = 1
            placeholderBar.layer?.removeAllAnimations()
            placeholderBar.alphaValue = 1
        }
        title.stringValue = ws.title
        lastTitle = ws.title
        let arrival = priorTitle?.isEmpty == true && !ws.title.isEmpty && !isPlaceholderRow
            && tunables.workspaceTitleMotion != .instant && !Motion.reduceMotion
        if arrival {
            titleArrivalPending = true
            titleArrivalVariant = tunables.workspaceTitleMotion
        } else {
            animateTitleChange(from: priorTitle, to: ws.title, variant: tunables.workspaceTitleMotion,
                               placeholder: isShowingPlaceholder || isPlaceholderRow)
        }
        title.font = ws.titleWeight.map { NSFont.systemFont(ofSize: SidebarStyle.titleFont.pointSize, weight: $0.font) } ?? SidebarStyle.titleFont
        subtitle.setFont(SidebarStyle.subtitleFont)
        subtitle.setString(row.detail ?? "")
        hasSubtitle = row.detail != nil
        (isExpanded, timeText) = (shown.expanded, shown.trailingText)
        timeLabel.setString(shown.trailingText ?? "")
        metaLabel.setString(shown.meta ?? "")
        activity.configure(badgesLead ? .idle : shown.activity, style: badgesLead ? nil : ws.activityStyle)
        activityState = shown.activity
        agentMarkVariant = content.agentMark
        let markImage = agentMarkVariant == .off || isShowingPlaceholder ? nil
            : ws.agentBrand.flatMap { AgentBrandCatalog.templateImage(brand: $0, size: agentMarkSize) }
        agentMark.image = markImage
        agentMark.isHidden = markImage == nil
        badge.configure(badgesLead ? .none : ws.unread)
        presenceDots.configure(content.presenceDots && !isShowingPlaceholder ? ws.presence : [])
        mutedMark.image = ws.muted && !isShowingPlaceholder
            ? NSImage.icon(symbol: "bell.slash", size: .iconRowSize(forLabelPointSize: SidebarStyle.indicatorSize - Metrics.space1)) : nil
        mutedMark.isHidden = mutedMark.image == nil
        disclosure = row.tabDisclosure
        count = row.tabCount
        disclosureButton.icon = row.tabDisclosure == .expanded ? .disclosureExpanded : .disclosureCollapsed
        disclosureButton.label = row.tabDisclosure == .expanded ? Strings.hideTabs : Strings.showTabs
        disclosureButton.setAccessibilityExpanded(row.tabDisclosure == .expanded)
        tabCount.setString(row.tabCount.map(String.init) ?? "")
        badgeText = shown.badge
        prBadge.setString(shown.badge ?? "")
        progress = shown.progress
        statusBlock.isHidden = shown.status == nil || isShowingPlaceholder
        statusBlock.configure(shown.status ?? SidebarWorkspaceStatus(), reservesBar: shown.progress != nil)
        statusHeight = statusBlock.isHidden ? 0 : SidebarLayoutMetrics.standard.statusHeight(shown)
        rowBadgeStyle = content.rowBadge
        configureBadges(ws, shown: shown, style: content.rowBadge, stackLimit: content.stackLimit)
        themedToolTip = nil // the workspace hover card shows the cwd (and CPU and memory)
        // A placeholder says nothing; its section header says it connects.
        setAccessibilityElement(!isShowingPlaceholder)
        setAccessibilityRole(.row)
        setAccessibilityIdentifier("cmux.sidebar.workspace.\(ws.id.rawValue)")
        setAccessibilityLabel(accessibilityText(ws, content: shown))
        needsLayout = true
        needsDisplay = true
    }

    /// Applies a title-only transition after the row's content has been set.
    /// CATransition snapshots the old and new glyphs in the same layer, which
    /// avoids the blank frame that a separate fade-out/fade-in would expose.
    private func animateTitleChange(from old: String?, to new: String,
                                    variant: SidebarWorkspaceTitleMotionVariant,
                                    placeholder: Bool) {
        guard !placeholder, let old, !old.isEmpty, !new.isEmpty, old != new,
              variant != .instant, !Motion.reduceMotion else { return }
        let transition: CATransition
        switch variant {
        case .instant: return
        case .crossfade: transition = Motion.crossfadeAction
        case .lift: transition = Motion.pushUpAction
        }
        transition.duration = variant == .crossfade ? Motion.duration(.crossfade) : Motion.duration(.fadeIn)
        transition.timingFunction = Motion.fadeCurve
        title.layer?.add(transition, forKey: "workspace-title-motion")
    }

    /// Starts after layout has placed both the title and its placeholder bar.
    /// The title transition and bar fade then share a frame, so a new name
    /// never flashes in after the loading state has already vanished.
    func startTitleArrival() {
        titleArrivalScheduled = false
        guard titleArrivalPending else { return }
        titleArrivalPending = false
        titleArrivalActive = true
        let generation = titleArrivalGeneration
        let variant = titleArrivalVariant
        title.isHidden = false
        placeholderBar.isHidden = false
        let transition: CATransition = switch variant {
        case .instant: Motion.crossfadeAction
        case .crossfade: Motion.crossfadeAction
        case .lift: Motion.pushUpAction
        }
        transition.duration = variant == .crossfade ? Motion.duration(.crossfade) : Motion.duration(.fadeIn)
        transition.timingFunction = Motion.fadeCurve
        title.layer?.add(transition, forKey: "workspace-title-motion")
        Motion.animate(.fadeOut, in: placeholderBar, { [weak placeholderBar] in
            placeholderBar?.animator().alphaValue = 0
        }, completion: { [weak self] in
            guard let self, self.titleArrivalGeneration == generation else { return }
            self.titleArrivalActive = false
            self.placeholderBar.alphaValue = 1
            self.placeholderBar.isHidden = true
        })
    }

    var renaming = false
}
