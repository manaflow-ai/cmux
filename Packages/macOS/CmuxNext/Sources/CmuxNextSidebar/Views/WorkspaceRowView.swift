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
    let title = MarqueeLabel(gate: Motion.sidebar)
    let subtitle = SidebarRowView.label(font: SidebarStyle.subtitleFont)
    /// Expanded rows (`sidebar.density`, cx-13w3; WorkspaceRowView+Expanded): the age and the meta line.
    let timeLabel = SidebarRowView.label(font: SidebarStyle.subtitleFont), metaLabel = SidebarRowView.label(font: SidebarStyle.subtitleFont)
    /// The row's status, in the sidebar's status colors (Lawrence msg 11983).
    let activity: StatusIndicatorView = { let view = StatusIndicatorView(); view.usesStatusColors = true; return view }()
    /// The running agent's brand mark (`SidebarAgentMarkVariant`); hidden when off.
    internal let agentMark = DecorativeImageView() // the row's label says the agent's state
    internal(set) var agentMarkVariant = SidebarAgentMarkVariant.off
    /// A harness mark with no registered icon or brand takes its workspace's stable color (WorkspaceRowView+Rendering).
    private(set) var agentMarkFallbackColor: GroupColor?
    /// The last configuration, so a Debug Settings switch of `sidebar.agentMark` redraws the row.
    internal(set) var lastConfiguration: (SidebarWorkspace, SidebarRow, SidebarRowBadgeStyle?)?
    var activityState = StatusIndicatorState.idle
    let badge = UnreadBadgeView(), rowBadge = RowBadgeView() // the count, and its replacement (WorkspaceRowView+Badges)
    var rowBadgeStyle = SidebarRowBadgeStyle.corner
    /// The agents acting in the workspace (`sidebar.presenceDots`, cx-gg84).
    let presenceDots = PresenceDotsView()
    /// A muted workspace (`notifications.mutedWorkspaces`): a quiet bell-slash
    /// in the trailing cluster, in the tertiary text color; hidden otherwise.
    let mutedMark = DecorativeImageView()
    /// A runaway agent chat in the workspace (`SidebarWorkspace.usageWarnings`: no autocompact
    /// cap, a huge context, a storm of subagents): a small warning triangle in the trailing
    /// cluster, apart from the working spinner; its tooltip says each rule and the number.
    let usageWarningMark = DecorativeImageView()
    /// The computer the workspace runs on (`WorkspaceRowContent.machine`): its icon in one neutral
    /// colour, a status mark's size, in the trailing column; hidden while the sidebar lists one machine.
    let machineMark = DecorativeImageView() // the row's label names the machine
    internal(set) var machine: SidebarMachineMark?
    /// The side `machineMark`'s image was drawn at.
    private var machineMarkSize: CGFloat = 0
    /// The workspace's tabs play sound (or are muted): a small speaker in the
    /// trailing cluster, always shown while they do, crossed out while they
    /// are muted. A click mutes or unmutes them (`onToggleAudio`).
    let audioButton = SidebarIconButton(icon: .browserTabAudio, pointSize: { Metrics.smallIconSize - Metrics.space2 }, label: Strings.muteTabs)
    internal(set) var audio: SidebarWorkspaceAudio?
    let closeButton = SidebarIconButton.rowClose(label: Strings.closeButton) // SidebarRowCloseButton
    /// The row's menu (cx-a9h6, ChatGPT project style): the right-click menu,
    /// under the button. Shows on hover only, over the end of the title
    /// behind a fade (Lawrence 2026-10-11: no layout shift).
    let moreButton = OverflowButton(label: Strings.workspaceMenu)
    /// An expanded pinned row's Unpin (cx-13w3), on hover beside the menu button.
    let pinButton = SidebarIconButton(icon: .statePinned, pointSize: { Metrics.smallIconSize - Metrics.space2 }, label: Strings.unpinWorkspace)
    /// `sidebar.workspaceRow.tabCount`: the workspace's tab count, in a fixed-width slot.
    let tabCount = SidebarRowView.label(font: SidebarStyle.subtitleFont)
    /// `sidebar.workspaceRow.pullRequest`: the PR / CI badge a hook reported.
    let prBadge = SidebarRowView.label(font: SidebarStyle.subtitleFont)
    var badgeText: String?
    /// The session tree (`sidebar.sessionTree`, WorkspaceRowView+SessionTree): a started workspace's
    /// guide line, the pull request badge and the keycap.
    let treeLine = NSView(), pullRequests = SidebarPullRequestBadgeView(), keycap = SidebarKeycapView()
    /// A tree parent's chevron (folds its subtree) and a folded parent's roll-up chips.
    let treeFoldButton = SidebarIconButton(icon: .disclosureExpanded, pointSize: { Metrics.smallIconSize - Metrics.space2 },
                                           label: Strings.collapseSessions), rollUp = SidebarTreeRollUpView()
    var treeDepth = 0
    var treeFold: SidebarTreeFold?
    var onToggleTree: (() -> Void)?
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
    /// The workspace's name, while the row draws another (`sidebar.rowTitle` focused tab, an inherited chat): calm
    /// mode's tooltip says it, since no hover card opens there.
    var hiddenWorkspaceName: String?
    /// An idle workspace nobody named: its name reads in the secondary ink (`SidebarTunables.quietUnnamedRows`).
    var isQuiet = false
    /// Archived in the sidebar document: the row draws dimmed (`SidebarStyle.archivedAlpha`).
    var isArchived = false
    var iconKind: WorkspaceIcon?
    /// The workspace color as a leading rail or a full fill (`WorkspaceRowView+Color`).
    var rowColor: (color: GroupColor, style: WorkspaceColorIndicatorStyle)?, colorRail = NSView()
    /// Selected but not active (the active row paints the selection fill).
    var isSecondarySelected = false {
        didSet {
            guard isSecondarySelected != oldValue else { return }
            updateAccessibilitySelection()
            needsDisplay = true
        }
    }
    /// On screen in this window but not the focused one (`SidebarModel.onScreen`): the soft fill.
    var isOnScreen = false { didSet { if isOnScreen != oldValue { needsDisplay = true } } }
    override var showsSelection: Bool { isSelected || isSecondarySelected }
    /// A tab dragged from a pane would move into this workspace.
    var isDropTarget = false { didSet { if isDropTarget != oldValue { needsDisplay = true } } }
    /// The keyboard focused the group this row stands for (`SidebarRow.standsForGroup`): its header's focus ring.
    var isKeyboardFocused = false { didSet { if isKeyboardFocused != oldValue { needsDisplay = true } } }
    /// The group this row stands for (`SidebarRow.standsForGroup`): its header's VoiceOver state and actions.
    var standingGroup: StandingGroupAccess? {
        didSet { setAccessibilityExpanded(standingGroup?.expanded ?? false) } // the header's AXExpanded; a plain row's stays off
    }
    var onClose: (() -> Void)?
    var onMore: (() -> Void)?
    /// The menu the more button opened is open (`SidebarRowMenu`): the hover controls stay shown and the more
    /// button stays lit after the pointer leaves for the menu (Leo 2026-10-26: "you keep it on when you click the
    /// context menu"). The row's own fill does not change: only the button lights (Leo 2026-10-27).
    var showsMenu = false {
        didSet {
            guard showsMenu != oldValue else { return }
            moreButton.showsMenu = showsMenu
            needsLayout = true
        }
    }
    /// The hover controls (more, close, the chevron) show: under the pointer, or while their menu is open.
    var revealsHoverControls: Bool { isHovered || showsMenu }
    /// nil: the App offers no pin; the pin button does not show.
    var onPin: (() -> Void)?, isPinned: (() -> Bool?)?
    /// Activates this workspace from an accessibility AXPress.
    var onSelect: (() -> Void)?
    var onToggleAudio: (() -> Void)?
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
        usageWarningMark.imageScaling = .scaleProportionallyDown
        usageWarningMark.isHidden = true
        usageWarningMark.setAccessibilityElement(false)
        machineMark.imageScaling = .scaleProportionallyDown
        machineMark.isHidden = true
        [icon, title, subtitle, timeLabel, metaLabel, activity, agentMark, mutedMark, usageWarningMark, machineMark, audioButton, badge, rowBadge, presenceDots, closeButton, moreButton, pinButton, tabCount, prBadge, placeholderBar, statusBlock,
         treeLine, pullRequests, keycap, treeFoldButton, rollUp].forEach(addSubview)
        setUpSessionTree()
        tabCount.isHidden = true
        prBadge.isHidden = true
        prBadge.lineBreakMode = .byTruncatingTail
        tabCount.alignment = .right
        tabCount.font = .monospacedDigitSystemFont(ofSize: SidebarStyle.subtitleFont.pointSize, weight: .regular)
        progressTrack.addSublayer(progressFill)
        progressTrack.isHidden = true
        layer?.addSublayer(progressTrack)
        closeButton.isHidden = true
        audioButton.isHidden = true
        placeholderBar.wantsLayer = true
        placeholderBar.layer?.cornerRadius = Metrics.chipCornerRadius(height: SidebarStyle.placeholderBarHeight)
        placeholderBar.isHidden = true
        title.wantsLayer = true
        closeButton.onPress = { [weak self] in self?.onClose?() }
        moreButton.onPress = { [weak self] in self?.onMore?() }
        pinButton.onPress = { [weak self] in self?.onPin?() }
        audioButton.onPress = { [weak self] in self?.onToggleAudio?() }
    }

    override var interactiveSubviews: [NSView] { [closeButton, moreButton, pinButton, treeFoldButton, audioButton] }
    override var debugArchived: Bool { isArchived }
    override var debugIcon: String? {
        switch iconKind {
        case nil: !agentMark.isHidden && agentMarkVariant == .besideTitle ? "agentMark" : nil
        case .symbol?: "symbol"
        case .swatch?: "swatch"
        case .emoji?: "emoji"
        case .favicon?: "favicon"
        }
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
        isOnScreen = false
        isDropTarget = false
        isKeyboardFocused = false
        standingGroup = nil
        onClose = nil
        onMore = nil
        showsMenu = false
        (onPin, isPinned) = (nil, nil)
        onSelect = nil
        onToggleTree = nil
        onToggleAudio = nil
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
        var rowTitle: SidebarRowTitleMode, rowTitleSingleChat: Bool
        var row: WorkspaceRowContent?
    }

    func configure(_ ws: SidebarWorkspace, row: SidebarRow, badgeStyle: SidebarRowBadgeStyle? = nil) {
        lastConfiguration = (ws, row, badgeStyle)
        let tunables = observedTunables()
        let content = Content(
            ws: ws, group: row.group,
            fontSize: SidebarStyle.titleFont.pointSize, iconSize: SidebarStyle.leadingGlyphSide,
            agentMark: tunables.agentMark, presenceDots: tunables.presenceDots, rowBadge: badgeStyle ?? tunables.rowBadge, stackLimit: tunables.stackCap.limit,
            rowTitle: tunables.rowTitle, rowTitleSingleChat: tunables.rowTitleSingleChat,
            row: row.content
        )
        guard needsConfigure(content) else { return }
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
        // its corner badge sits in the trailing slot (`layoutColumnMark`).
        let badgesLead = content.rowBadge != .trailing && !isShowingPlaceholder
        icon.configure(icon: shown.icon)
        iconKind = shown.icon
        configureColor(shown)
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
        // The name the row draws (`sidebar.rowTitle`): the workspace's, else a breadcrumb to its focused tab.
        let shownTitle = ws.rowTitle(content.rowTitle, inheritsSingleChat: content.rowTitleSingleChat)
        title.stringValue = shownTitle
        lastTitle = shownTitle
        hiddenWorkspaceName = ws.namesWorkspace(shownTitle) ? nil : ws.title
        isQuiet = tunables.quietUnnamedRows && ws.isUnnamed && !ws.unread.isUnread && ws.activity == .idle && !ws.agentWorking
        isArchived = ws.isArchived
        icon.alphaValue = isArchived ? SidebarStyle.archivedAlpha : 1
        let arrival = priorTitle?.isEmpty == true && !shownTitle.isEmpty && !isPlaceholderRow
            && tunables.workspaceTitleMotion != .instant && Motion.sidebar.animatesMovement
        if arrival {
            titleArrivalPending = true
            titleArrivalVariant = tunables.workspaceTitleMotion
        } else {
            animateTitleChange(from: priorTitle, to: shownTitle, variant: tunables.workspaceTitleMotion,
                               placeholder: isShowingPlaceholder || isPlaceholderRow)
        }
        title.font = ws.titleWeight.map { NSFont.systemFont(ofSize: SidebarStyle.titleFont.pointSize, weight: $0.font) } ?? SidebarStyle.titleFont
        subtitle.setFont(SidebarStyle.subtitleFont)
        subtitle.setString(shown.now.map(Strings.rowNow) ?? row.detail ?? "")
        hasSubtitle = row.detail != nil
        // No status words and no running time on a row (Leo 2026-10-21): its badge's dot says it; the label reads the chip.
        let trailingText = shown.trailingText
        (isExpanded, timeText) = (shown.expanded, trailingText)
        timeLabel.setString(trailingText ?? "")
        metaLabel.setString(shown.meta ?? "")
        activity.configure(badgesLead ? .idle : shown.activity, style: badgesLead ? nil : ws.activityStyle)
        activityState = shown.activity
        agentMarkVariant = content.agentMark
        let markImage = Self.agentMarkImage(ws, variant: agentMarkVariant, placeholder: isShowingPlaceholder)
        agentMarkFallbackColor = isShowingPlaceholder ? nil : Self.agentMarkFallbackColor(ws, variant: agentMarkVariant)
        agentMark.image = markImage
        agentMark.isHidden = markImage == nil
        badge.configure(badgesLead ? .none : ws.unread)
        presenceDots.configure(content.presenceDots && !isShowingPlaceholder ? ws.presence : [])
        mutedMark.image = ws.muted && !isShowingPlaceholder
            ? NSImage.icon(symbol: "bell.slash", size: .iconRowSize(forLabelPointSize: SidebarStyle.indicatorSize - Metrics.space1)) : nil
        mutedMark.isHidden = mutedMark.image == nil
        // The bell-slash alone does not say what is muted: notifications, not the tabs' sound
        // (the row's accessibility label says it too).
        mutedMark.themedToolTip = mutedMark.isHidden ? nil : Strings.notificationsMuted
        // acpmux's own lines name the rule and the number ("90 subagents started in the last hour, above 40").
        usageWarningMark.image = ws.usageWarnings.isEmpty || isShowingPlaceholder ? nil
            : NSImage.icon(symbol: "exclamationmark.triangle.fill", size: .iconRowSize(forLabelPointSize: SidebarStyle.indicatorSize - Metrics.space1))
        usageWarningMark.isHidden = usageWarningMark.image == nil
        usageWarningMark.themedToolTip = usageWarningMark.isHidden ? nil : ws.usageWarnings.joined(separator: "\n")
        let previousMachine = machine
        machine = isShowingPlaceholder ? nil : shown.machine
        // A new image only when the mark or its size changes: every patch and every row scrolled in configures the row.
        let machineSize = SidebarStyle.statusGlyphSize // drawn at its box's size, as the status marks beside it
        if machine != previousMachine || machineSize != machineMarkSize || (machine != nil && machineMark.image == nil) {
            machineMarkSize = machineSize
            machineMark.image = machine.map { Self.machineMarkImage($0, side: machineSize) }
        }
        machineMark.isHidden = machineMark.image == nil
        audio = isShowingPlaceholder ? nil : ws.audio
        audioButton.isHidden = audio == nil
        audioButton.icon = audio == .muted ? .browserTabMuted : .browserTabAudio
        audioButton.label = audio == .muted ? Strings.unmuteTabs : Strings.muteTabs
        count = row.tabCount
        tabCount.setString(row.tabCount.map(String.init) ?? "")
        badgeText = shown.badge
        prBadge.setString(shown.badge ?? "")
        configureSessionTree(shown)
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
        for (button, control) in [(closeButton, "close"), (moreButton, "more"), (pinButton, "pin")] as [(NSButton, String)] {
            button.setAccessibilityIdentifier("cmux.sidebar.workspace.\(ws.id.rawValue).\(control)")
        }
        setAccessibilityLabel(accessibilityText(ws, content: shown,
                                                title: ws.spokenRowTitle(content.rowTitle, inheritsSingleChat: content.rowTitleSingleChat)))
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
              variant != .instant, Motion.sidebar.animatesMovement else { return }
        let transition: CATransition
        switch variant {
        case .instant: return
        case .crossfade: transition = Motion.crossfadeAction
        case .lift: transition = Motion.pushUpAction
        }
        transition.duration = variant == .crossfade ? Motion.sidebar.duration(.crossfade) : Motion.sidebar.duration(.fadeIn)
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
        transition.duration = variant == .crossfade ? Motion.sidebar.duration(.crossfade) : Motion.sidebar.duration(.fadeIn)
        transition.timingFunction = Motion.fadeCurve
        title.layer?.add(transition, forKey: "workspace-title-motion")
        Motion.sidebar.animate(.fadeOut, in: placeholderBar, { [weak placeholderBar] in
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
