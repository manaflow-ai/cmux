import AppKit
import CmuxNextDesign
import CmuxNextIcons
import CmuxNextResources
import CmuxNextWakeups

/// The workspace hover card (Codex parity, Leo 2026-10-08): a title row
/// (the name, a kind or host icon, the relative age) and one row per
/// meaningful fact (`WorkspaceHoverCardContent`); CPU and memory summed over
/// its tabs show as one muted line, only when notable. It replaces the row
/// tooltip.
///
/// Resources are sampled only while the card's details are expanded; collapsing
/// details or hiding the card stops sampling.
final class WorkspaceHoverCardController: HoverCardSource {
    let resources = ResourceCardSampler(source: nil)
    /// Hover time before a card shows: `HoverCardTiming.showDelay`, or
    /// `sidebar.hoverCards.delay` (cx-23e1f), so a sweep down the list shows
    /// none and leaving a row cancels its pending card. Once a card shows,
    /// moving down the list slides it over at once.
    var delay: Duration { DesignSettings.shared.hoverCardDelay }
    /// Lawrence 2026-10-19: "We need it to instantly disappear with fade opacity when I mouse
    /// out." The card touches its row, so it needs no grace for the pointer to travel to it:
    /// leaving the row and the card fades it out at once, as a tab card does. A gap or header
    /// between rows (`hoverCardBridges`) holds it for the reshow window, so the next row slides
    /// it over instead of hiding and reshowing it. Leo 2026-10-21: the card's top lines up with
    /// its row's top, touching the row's fill (`HoverCardPlacement.besideRow`).
    var leave: HoverCardLeave { .hides(reshow: HoverCardTiming.reshowWindow) }
    weak var list: SidebarListView?
    /// The app's one coordinator; the App injects it.
    var coordinator: HoverCardCoordinator {
        didSet {
            guard coordinator !== oldValue else { return }
            oldValue.unregister(self)
            if list?.window != nil { coordinator.register(self) }
        }
    }
    private var body: WorkspaceHoverCardView?
    /// The group headers' summary card body, reused group to group.
    private var groupBody: GroupHoverCardView?
    private var bodyID: HoverTargetID?
    /// The card "Show Resource Usage" asked for: it opens with its details (and the resource
    /// line) expanded, since that is what the action shows. Cleared when that card hides.
    private var detailsRequested: HoverTargetID?
    /// Ticks the shown card's running times once a second (one-shot, re-armed by each tick);
    /// idle while no live card shows, so a quiet sidebar wakes nothing.
    private let ticker = DemandTimer(owner: "sidebar.hover-card.elapsed")
    /// The user's customization (`cmux.hovercard/1`); the App injects it.
    var customization: (any SidebarCustomization)?
    /// A workspace's history of prompts, waits and finished turns (u3320); the App injects it.
    var timelineSource: SidebarTimelineSource?
    /// How many moments a card reads: its stats count them all, its list shows `maxRows`.
    static let timelineReadLimit = 100
    /// The shown card's custom content and its workspace; released when the card hides or moves.
    private var custom: (id: WorkspaceID, content: any SidebarCustomContent)?

    init(coordinator: HoverCardCoordinator = HoverCardCoordinator()) {
        self.coordinator = coordinator
        #if DEBUG
        HoverCardGallery.register("sidebar") { WorkspaceHoverCardGallery.cards() }
        #endif
    }

    static func targetID(_ id: WorkspaceID) -> HoverTargetID { HoverTargetID("ws:\(id.rawValue)") }

    static func targetID(_ id: GroupID) -> HoverTargetID { HoverTargetID("grp:\(id.rawValue)") }

    private func groupID(_ id: HoverTargetID) -> GroupID? {
        id.rawValue.hasPrefix("grp:") ? GroupID(String(id.rawValue.dropFirst(4))) : nil
    }

    /// This list's group whose summary card shows now.
    var shownGroupID: GroupID? {
        guard let id = coordinator.machine.shownTarget?.id, let group = groupID(id), list?.groups[group] != nil else { return nil }
        return group
    }

    private func workspaceID(_ id: HoverTargetID) -> WorkspaceID? {
        id.rawValue.hasPrefix("ws:") ? WorkspaceID(String(id.rawValue.dropFirst(3))) : nil
    }

    /// This list's workspace whose card shows now.
    var shownID: WorkspaceID? {
        guard let id = coordinator.machine.shownTarget?.id, let ws = workspaceID(id), list?.hoverCardRow(ws) != nil else { return nil }
        return ws
    }

    var isVisible: Bool { shownID != nil || shownGroupID != nil }

    // MARK: HoverCardSource

    var hoverCardWindow: NSWindow? { list?.window }

    func hoverCardHit(at screenPoint: CGPoint) -> HoverCardHit? {
        guard let list, let window = list.window else { return nil }
        let point = list.convert(window.convertPoint(fromScreen: screenPoint), from: nil)
        if let group = list.hoverCardGroup(at: point), let anchor = list.hoverCardBand(forGroup: group) {
            // A group waits its own, longer delay: the person rests on it "for a while".
            return HoverCardHit(target: HoverTarget(id: Self.targetID(group), window: window.windowNumber,
                                                    delay: DesignSettings.shared.groupHoverCard.delay, leave: leave),
                                anchor: anchor)
        }
        guard let id = list.hoverCardWorkspace(at: point), let anchor = list.hoverCardBand(for: id),
              !Self.onPullRequestBadge((list.rowViews[.workspace(id)] as? WorkspaceRowView)?.pullRequests, window: window, screenPoint: screenPoint)
        else { return nil }
        return HoverCardHit(target: HoverTarget(id: Self.targetID(id), window: window.windowNumber, delay: delay, leave: leave),
                            anchor: anchor)
    }

    /// A point in the visible list on no row, between its first row and its last (a header, a
    /// gap between rows). The empty list below the last row bridges to nothing: the card goes
    /// there at once, as anywhere else off the row and the card (Leo 2026-10-20).
    func hoverCardBridges(at screenPoint: CGPoint) -> Bool {
        guard let list, let window = list.window, !list.isHiddenOrHasHiddenAncestor,
              let first = list.displayed.rows.first, let last = list.displayed.rows.last else { return false }
        let point = list.convert(window.convertPoint(fromScreen: screenPoint), from: nil)
        return list.visibleRect.contains(point) && point.y >= first.y && point.y < last.maxY
    }

    func hoverCardAnchor(for id: HoverTargetID) -> CGRect? {
        // Workspace fill or group band: the card touches its anchor, its top on the row's top.
        if let group = groupID(id) { return list?.hoverCardBand(forGroup: group) }
        return workspaceID(id).flatMap { list?.hoverCardBand(for: $0) }
    }

    func hoverCardTargetFrame(for id: HoverTargetID) -> CGRect? {
        if let group = groupID(id) { return list?.hoverCardAnchor(forGroup: group) }
        return workspaceID(id).flatMap { list?.hoverCardBand(for: $0) }
    }

    /// The pointer is on a row's pull request badge, whose own card (`SidebarPullRequestCard`)
    /// shows there instead.
    static func onPullRequestBadge(_ badge: SidebarPullRequestBadgeView?, window: NSWindow, screenPoint: CGPoint) -> Bool {
        guard let badge, !badge.isHidden, badge.badge?.items.isEmpty == false, SidebarPullRequestCardController.isEnabled
        else { return false }
        return window.convertToScreen(badge.convert(badge.bounds, to: nil)).contains(screenPoint)
    }

    func hoverCardBody(for id: HoverTargetID) -> HoverCardBody? {
        if let group = groupID(id) { return groupCardBody(for: group, id: id) }
        guard let list, let ws = workspaceID(id), let workspace = list.hoverCardRow(ws) else { return nil }
        let body = body ?? WorkspaceHoverCardView()
        body.widthCap = min(WorkspaceHoverCardView.maxCardWidth, list.bounds.width + WorkspaceHoverCardView.tokens.sidebarReach)
        if bodyID != id { body.resetDetails() }
        // Activation ran while the card was pending, before this body existed, so details
        // opened here (Show Resource Usage) start their sampling below, once bodyID is set.
        let openedByRequest = detailsRequested == id && !body.isDetailsExpanded
        if openedByRequest { body.expandDetails() }
        self.body = body
        let machine = list.sections.values.lazy.compactMap(\.machine).first { $0.id == workspace.machineID }
        let options = DesignSettings.shared.workspaceHoverCard
        let wantsTimeline = options.layout != .classic
        let timeline = wantsTimeline ? (timelineSource?(ws, Self.timelineReadLimit) ?? []) : []
        // The workspace on screen needs no digest: the person is looking at it.
        let looked = SidebarTunables.sinceLooked.value && ws != list.model.activeWorkspaceID ? SidebarLookedStore.shared.stamps[ws] : nil
        let content = WorkspaceHoverCardContent.make(workspace, machine: machine, now: Date(), options: options, timeline: timeline,
                                                     looked: looked, pullRequests: SidebarSessionTree.shared.pullRequests[ws])
        body.configure(content)
        body.configureTabs(title: ws.rawValue, tabs: workspace.tabs, machine: machine)
        body.onDetailsChanged = { [weak self] in self?.detailsChanged(id) }
        body.tabList.onSelect = { [weak self, weak list] tabID in
            guard let self else { return }
            if let list, list.hoverCardRow(ws)?.tabs.contains(where: { $0.id == tabID }) == true {
                list.model.send(.selectTab(workspace: ws, tab: tabID))
            }
            self.coordinator.dismiss(.action)
        }
        // A row's ✕ closes its tab and the card stays: the workspace's next tabs reach it through
        // `contentChanged` (Leo 2026-11-02: "YOU SHOULD BE ABLE TO CLOSE THESE TABS FROM THE HOVER PREVIEW").
        body.tabList.onClose = { [weak list] tabID in
            guard let list, list.hoverCardRow(ws)?.tabs.contains(where: { $0.id == tabID }) == true else { return }
            list.model.send(.closeTab(workspace: ws, tab: tabID))
        }
        body.setResources(resources.report)
        bodyID = id
        if openedByRequest { startSampling(id) }
        body.setCustom(customContent(for: ws, id: id, card: content.cardFacts))
        updateTicker()
        return HoverCardBody(view: body, placement: .besideRow, themeAnchor: list, interactive: true) { [weak body] in body?.applyColors() }
    }

    /// A group header's summary card (`GroupHoverCardSummary`): no sampling, no ticker.
    private func groupCardBody(for group: GroupID, id: HoverTargetID) -> HoverCardBody? {
        guard let list, let item = list.groups[group] else { return nil }
        let body = groupBody ?? GroupHoverCardView()
        groupBody = body
        body.configure(Self.groupSummary(item, workspaces: list.subtreeWorkspaces(of: group),
                                         options: DesignSettings.shared.groupHoverCard, now: Date()))
        bodyID = id
        // One rule for sidebar cards: beside the sidebar, its top on the header's, touching the edge.
        return HoverCardBody(view: body, placement: .besideRow, themeAnchor: list) { [weak body] in body?.applyColors() }
    }

    /// What `group`'s card says: `workspaces` (its own and its subgroups') as the shared group summary counts them.
    static func groupSummary(_ group: SidebarGroup, workspaces: [SidebarWorkspace], options: GroupHoverCardOptions,
                             now: Date) -> GroupHoverCardSummary {
        let members = workspaces.map { ws in
            GroupHoverCardMember(title: ws.title, activity: GroupHoverCardMember.Activity(ws.agentWorking && ws.activity == .idle ? .working : ws.activity),
                                 unread: Self.unreadCount(ws.unread), lastActivity: ws.lastActivity, branch: ws.branch, ports: ws.ports)
        }
        return GroupHoverCardSummary.make(title: SidebarGroup.named(group.name), kind: .workspaceGroup, members: members, options: options, now: now)
    }

    private static func unreadCount(_ unread: UnreadState) -> Int {
        switch unread {
        case .none: 0
        case .dot: 1
        case let .count(n): max(0, n)
        }
    }

    func hoverCardActivated(_ id: HoverTargetID) {
        guard bodyID == id, body?.isDetailsExpanded == true else { return }
        startSampling(id)
    }

    /// Samples `id`'s workspace while its details are open.
    private func startSampling(_ id: HoverTargetID) {
        guard let ws = workspaceID(id) else { return }
        resources.open(.workspace(ws.rawValue)) { [weak self] report in
            guard let self, self.bodyID == id else { return }
            self.body?.setResources(report)
            self.coordinator.contentChanged(id)
        }
    }

    /// Show Resource Usage: the next card shown for `ws` opens with its details expanded.
    func requestDetails(for ws: WorkspaceID) { detailsRequested = Self.targetID(ws) }

    func hoverCardDeactivated(_ id: HoverTargetID) {
        if detailsRequested == id { detailsRequested = nil }
        resources.close()
        body?.resetResourceHistory()
        body?.tabList.onSelect = nil
        body?.tabList.onClose = nil
        body?.onDetailsChanged = nil
        bodyID = nil
        releaseCustom()
        updateTicker()
        // The card the pointer rested on hid: a sidebar change held while it was read shows now,
        // unless the pointer is back over the rows.
        list?.releaseHeldModelChangeIfPointerLeft()
    }

    private func detailsChanged(_ id: HoverTargetID) {
        if body?.isDetailsExpanded == true {
            startSampling(id)
        } else {
            resources.close()
        }
        updateTicker()
        coordinator.refit(id)
    }

    /// The custom card for `ws`, mounted once per shown card; nil without a customization.
    private func customContent(for ws: WorkspaceID, id: HoverTargetID, card: SidebarCardFacts) -> (any SidebarCustomContent)? {
        if let custom, custom.id == ws { return custom.content }
        releaseCustom()
        guard let content = customization?.hoverCard(forWorkspace: ws.rawValue, card: card) else { return nil }
        content.onChange = { [weak self, weak content] in
            guard let self, let content, self.bodyID == id else { return }
            self.body?.setCustom(content)
            self.coordinator.contentChanged(id)
        }
        custom = (ws, content)
        return content
    }

    private func releaseCustom() {
        custom?.content.onChange = nil
        custom?.content.release()
        custom = nil
    }

    /// Arms the next one-second tick while a card with a running time shows, stops it otherwise.
    private func updateTicker() {
        // A group's summary card has no running time: only a workspace card ticks.
        guard let id = bodyID, workspaceID(id) != nil, let body, let delay = body.nextTickDelay else {
            ticker.cancel()
            return
        }
        guard !ticker.isScheduled else { return }
        ticker.schedule(after: delay) { @MainActor [weak self] in self?.tickShownCard() }
    }

    private func tickShownCard() {
        guard let id = bodyID, let body else { return }
        if body.tick(now: Date()) { coordinator.contentChanged(id) }
        updateTicker()
    }

    /// Design tokens changed: the next card rebuilds at the new sizes.
    func tokensChanged() {
        coordinator.dismiss(.action)
        body = nil
        groupBody = nil
        bodyID = nil
    }
}

/// The workspace card body. One instance is reused for every workspace
/// card; the app's one `HoverCardPanel` hosts it.
final class WorkspaceHoverCardView: NSView, HoverCardInteractiveBody, HoverCardTextReporting {
    enum TabPlacement { case afterTitle, afterStatus, afterDetails }
    let tabList: WorkspaceTabHoverCardView
    private let tabPlacement: TabPlacement

    func handleHoverCardKeyDown(_ event: NSEvent) -> Bool { tabList.handleHoverCardKeyDown(event) }
    /// Every size of the card at the sidebar's density and text size (``SidebarRowTokens/hoverCard``): a pinned row
    /// and a list row open this card, so it follows the rows (Lawrence 2026-11-03: "make sure size of the pinned
    /// summary thing reflect size of ui compactness i chose"). Read at configure time, so a change applies live.
    static var tokens: SidebarHoverCardMetrics { SidebarRowTokens.current.hoverCard }
    private static var padding: CGFloat { tokens.padding }
    /// The card sizes to its content between these widths (POLISH: no
    /// blank band beside a short name); a long name wraps at the widest.
    static var cardWidth: CGFloat { tokens.width }
    /// The card's widest by default: the tab rows' details read whole up to it (the owner, on msg 19245's
    /// gallery: "the card is too narrow to show the detail you added").
    static var maxCardWidth: CGFloat { tokens.maxWidth }
    /// This card's widest: `maxCardWidth`, or less beside a narrow sidebar (its width plus `tokens.sidebarReach`);
    /// nil for `maxCardWidth` at the sizes now.
    var widthCap: CGFloat?
    static var minCardWidth: CGFloat { tokens.minWidth }
    /// The full history layout's width: a prompt reads in longer lines (u3320).
    static var logCardWidth: CGFloat { tokens.logWidth }
    /// How tall the history may grow before it scrolls: the default card, and the full history.
    static var timelineMaxHeight: CGFloat { tokens.timelineMaxHeight }
    static var logMaxHeight: CGFloat { tokens.logMaxHeight }
    /// The card's one icon column's width: the kind icon, the status mark, each fact's and each tab's icon.
    static var iconSize: CGFloat { tokens.iconSide }
    /// The name, the host and a fact's text; the age, stats, summary and error lines.
    private static var titleFont: NSFont { Typography.bodyEmphasized.withSize(tokens.titleSize) }
    private static var bodyFont: NSFont { Typography.system(.default, size: tokens.titleSize, weight: .regular) }
    private static var captionFont: NSFont { Typography.system(.default, size: tokens.captionSize, weight: .regular) }
    /// Where every row's text starts, past the icon column: the name, the status word, the stats, each
    /// fact, each tab's title and detail line, "Show N more" and "Show details" share this one leading edge
    /// (Lawrence msg 19245: "alignment here looks bad").
    static var textInset: CGFloat { iconSize + Metrics.space2 }
    /// The body font with digits of one width, for lines whose running time ticks.
    private static var liveFont: NSFont { Typography.system(.monospacedDigit, size: tokens.titleSize, weight: .regular) }

    /// When the card's running times next change their text: every second under an hour, then
    /// every minute ("1h 3m"); nil when nothing runs.
    var nextTickDelay: Duration? {
        guard isLive, let content else { return nil }
        let starts = ([content.activitySince] + content.facts.map(\.since)).compactMap { $0 }
        guard let newest = starts.max() else { return nil }
        return Date().timeIntervalSince(newest) < 3600 ? .seconds(1) : .seconds(60)
    }

    private let titleLabel = ChromeLabel(labelWithString: "")
    /// The kind icon, leading the name on the card's icon column; a Cloud or remote card has none
    /// (its machine reads once, in `hostLabel`).
    private let kindIcon = HoverCardIconView()
    /// Where a Cloud or remote workspace runs ("Cloud", the host's name), once, in the secondary ink
    /// after the name, its reachability dot beside it; local has none (Leo 2026-11-02, on a card that
    /// said Cloud four times: "the tiny cloud icon the repeated cloud cloud cloud").
    let hostLabel = ChromeLabel(labelWithString: "")
    private let hostDot = HoverCardAccessoryView()
    /// The workspace's status in the shared indicator, on its own row under the name with its
    /// word beside it (Leo 2026-10-13: an unlabeled mark under the name read as a smudge).
    private let activity: StatusIndicatorView = { let view = StatusIndicatorView(); view.tracksWindowOcclusion = true; return view }()
    private let activityLabel = ChromeLabel(labelWithString: "")
    private let activityRow = NSStackView()
    private let ageLabel = ChromeLabel(labelWithString: "")
    private let factsStack = NSStackView()
    /// CPU and memory with the last seconds of CPU as bars (`WorkspaceHoverCardContent.resourceRow`).
    private let resourceRow = HoverCardRowView()
    /// "Prompts: 4 · Worked 12m", under the status (u3320).
    private let statsLabel = ChromeLabel(labelWithString: "")
    /// The stats line's row, which puts it on the text column (hidden with it).
    private let statsRow = NSStackView()
    /// Rex-style default: tabs are the useful affordance; rich details stay behind an explicit toggle.
    let detailsToggle = WorkspaceHoverCardDisclosure()
    /// The summary header's line under the name: tab count, running and unread (`style.header`).
    private let summaryLabel = ChromeLabel(labelWithString: "")
    private let summaryRow = NSStackView()
    let style: WorkspaceTabHoverCardStyle
    private var detailsExpanded = false
    var isDetailsExpanded: Bool { detailsExpanded }
    var onDetailsChanged: (() -> Void)?
    /// The scrollable history of prompts, waits and finished turns (u3320).
    let timeline = WorkspaceHoverCardTimelineView()
    /// The card's widest; the full history layout widens it.
    private var widthLimit: NSLayoutConstraint?
    private var width: CGFloat = WorkspaceHoverCardView.cardWidth
    /// The constraints the tokens size, and how (`applySizes`).
    private var sized: [(NSLayoutConstraint, (SidebarHoverCardMetrics) -> CGFloat)] = []
    private var activitySlot: HoverCardIconSlot?
    /// The user's card (`cmux.hovercard/1`) once its first scene arrives; the built-in rows hide.
    private let customSlot = NSView()
    /// Why the user's card did not render: shown under the built-in card, which stays.
    private let customError = ChromeLabel(wrappingLabelWithString: "")
    private weak var customView: NSView?
    private var customHeight: NSLayoutConstraint?
    /// The last resource line, shown only with the built-in card.
    private var resourceShown = false
    /// The CPU of each sample since the card showed, newest last (its bars).
    private var cpuHistory: [Double] = []
    /// The report behind the newest bar, so a repeat of it adds none.
    private var lastSampled: ResourceReport?
    /// One shared row per fact (`HoverCardRowView`), reused card to card.
    private var factViews: [HoverCardRowView] = []
    /// The built-in card's rows (hidden while the user's card shows).
    private var builtIn: [NSView] = []
    /// The shown content, for the live elapsed times (`tick`).
    private var content: WorkspaceHoverCardContent?
    /// Hidden history is measured only when details open, never on a hover retarget.
    private var pendingTimelineAt: Date?
    /// The machine `hostLabel` names, whose color pick (`appearance.machineColors`) it draws in.
    private var hostMachine: String?
    /// The shown status word, before its elapsed time.
    private var activityWord: String?

    init(tabPlacement: TabPlacement = .afterTitle, style: WorkspaceTabHoverCardStyle = .standard) {
        self.tabPlacement = tabPlacement
        self.style = style
        tabList = WorkspaceTabHoverCardView(style: style)
        super.init(frame: .zero)
        let content = self
        // The whole name, wrapped: the card is where a clipped row title
        // reads in full (also under Reduce Motion, which has no marquee).
        titleLabel.lineBreakMode = .byWordWrapping
        titleLabel.maximumNumberOfLines = 6
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // The name hugs its text so the machine and its dot read right after it, not at the far edge.
        titleLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        hostLabel.lineBreakMode = .byTruncatingTail
        hostLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        hostLabel.setContentHuggingPriority(.required, for: .horizontal)
        hostLabel.isHidden = true
        hostDot.line = titleLabel
        hostDot.setContentHuggingPriority(.required, for: .horizontal)
        hostDot.setContentCompressionResistancePriority(.required, for: .horizontal)
        hostDot.isHidden = true
        ageLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        ageLabel.setContentHuggingPriority(.required, for: .horizontal)
        kindIcon.setContentHuggingPriority(.required, for: .horizontal)
        kindIcon.line = titleLabel
        // Digits of one width: a running time that ticks keeps its width ("1m 11s", "1m 18s").
        activityLabel.lineBreakMode = .byTruncatingTail
        resourceRow.isHidden = true
        statsLabel.lineBreakMode = .byTruncatingTail
        timeline.isHidden = true
        detailsToggle.title = Strings.showDetails
        detailsToggle.onPress = { [weak self] in self?.toggleDetails() }

        // Every icon sits on one column at the leading inset, its text beside it (the fact rows'
        // grid), so the kind icon leads the name instead of floating after it.
        let titleRow = NSStackView()
        titleRow.setViews([kindIcon, titleLabel, hostDot, hostLabel], in: .leading)
        titleRow.setViews([ageLabel], in: .trailing)
        titleRow.orientation = .horizontal
        titleRow.alignment = .firstBaseline
        titleRow.spacing = Metrics.space2
        // The indicator's slot is a box that never hides, so a style that draws no glyph keeps the
        // word on the text column.
        let activitySlot = HoverCardIconSlot(side: Self.iconSize, line: activityLabel)
        self.activitySlot = activitySlot
        activity.translatesAutoresizingMaskIntoConstraints = false
        activitySlot.addSubview(activity)
        activityRow.setViews([activitySlot, activityLabel], in: .leading)
        activityRow.orientation = .horizontal
        // The mark on the word's capitals, as every icon on the card (`HoverCardIconSlot`).
        activityRow.alignment = .firstBaseline
        activityRow.spacing = Metrics.space2
        factsStack.orientation = .vertical
        factsStack.alignment = .leading
        factsStack.spacing = Metrics.space2

        customError.maximumNumberOfLines = 3
        customError.isHidden = true
        customSlot.isHidden = true
        // The stats line reads on the text column with the name and the facts, not under the icons.
        statsRow.setViews([statsLabel], in: .leading)
        statsRow.isHidden = true
        // The summary line starts on the text column too, not under the icons.
        summaryLabel.lineBreakMode = .byTruncatingTail
        summaryRow.setViews([summaryLabel], in: .leading)
        summaryRow.isHidden = true
        builtIn = [activityRow, statsRow, factsStack, timeline, resourceRow]
        // The shipped card is Rex-style: tabs are immediately available and a one-click
        // details disclosure keeps the existing rich content available. Gallery variants
        // retain their requested tab placement when details are expanded.
        var rows: [NSView] = [customSlot, titleRow, summaryRow, activityRow, statsRow, factsStack, timeline, resourceRow, customError]
        let tabIndex = tabPlacement == .afterTitle ? 3 : (tabPlacement == .afterStatus ? 5 : 9)
        rows.insert(tabList, at: tabIndex)
        rows.insert(detailsToggle, at: tabIndex + 1)
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Metrics.space3
        // Show details reads as the list's last row, on the rows' spacing.
        stack.setCustomSpacing(Metrics.space1, after: tabList)
        stack.setCustomSpacing(Metrics.space1, after: titleRow)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        let widthLimit = content.widthAnchor.constraint(lessThanOrEqualToConstant: Self.cardWidth)
        self.widthLimit = widthLimit
        sized = [
            (content.widthAnchor.constraint(greaterThanOrEqualToConstant: Self.minCardWidth), \.minWidth),
            (stack.topAnchor.constraint(equalTo: content.topAnchor), \.padding),
            (stack.bottomAnchor.constraint(equalTo: content.bottomAnchor), { -$0.padding }),
            (stack.leadingAnchor.constraint(equalTo: content.leadingAnchor), \.padding),
            (stack.trailingAnchor.constraint(equalTo: content.trailingAnchor), { -$0.padding }),
        ] + [kindIcon.widthAnchor, kindIcon.heightAnchor, activitySlot.widthAnchor, activitySlot.heightAnchor,
             activity.widthAnchor, activity.heightAnchor].map { ($0.constraint(equalToConstant: Self.iconSize), \.iconSide) }
        NSLayoutConstraint.activate(sized.map(\.0) + [
            widthLimit,
            timeline.widthAnchor.constraint(equalTo: stack.widthAnchor),
            tabList.widthAnchor.constraint(equalTo: stack.widthAnchor),
            detailsToggle.widthAnchor.constraint(equalTo: stack.widthAnchor),
            titleRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            factsStack.widthAnchor.constraint(equalTo: stack.widthAnchor),
            resourceRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            activity.centerXAnchor.constraint(equalTo: activitySlot.centerXAnchor),
            activity.centerYAnchor.constraint(equalTo: activitySlot.centerYAnchor),
        ])
        applySizes()
    }

    /// Takes the card's sizes at the sidebar's density and text size now (``SidebarRowTokens/hoverCard``): fonts,
    /// padding, the icon column and the width bounds. The card is reused from show to show, so `configure` runs it.
    private func applySizes() {
        let tokens = Self.tokens
        titleLabel.font = Self.titleFont
        hostLabel.font = Self.bodyFont
        ageLabel.font = Self.captionFont
        activityLabel.font = Self.liveFont
        statsLabel.font = Typography.system(.monospacedDigit, size: tokens.captionSize, weight: .regular)
        customError.font = Self.captionFont
        summaryLabel.font = Self.captionFont
        kindIcon.side = tokens.iconSide
        activitySlot?.side = tokens.iconSide
        statsRow.edgeInsets = NSEdgeInsets(top: 0, left: Self.textInset, bottom: 0, right: 0)
        summaryRow.edgeInsets = NSEdgeInsets(top: 0, left: Self.textInset, bottom: 0, right: 0)
        for (constraint, value) in sized { constraint.constant = value(tokens) }
        resourceRow.iconSide = tokens.iconSide
        factViews.forEach { $0.iconSide = tokens.iconSide }
        detailsToggle.applySizes()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The text the card shows, one entry per row (tests, accessibility).
    var lines: [String] {
        if !customSlot.isHidden { return ["custom card"] + (hostLabel.isHidden ? [] : [hostLabel.stringValue]) + Self.texts(in: customSlot) + tabList.reportedLines }
        var lines = [[titleLabel.stringValue, hostLabel.isHidden ? "" : hostLabel.stringValue, ageLabel.isHidden ? "" : ageLabel.stringValue]
            .filter { !$0.isEmpty }.joined(separator: " ")]
        if !activityRow.isHidden { lines.append(activityLabel.stringValue) }
        if !statsRow.isHidden { lines.append(statsLabel.stringValue) }
        if !factsStack.isHidden { lines += factViews.filter { !$0.isHidden }.map(\.shownText) }
        if !summaryRow.isHidden { lines.append(summaryLabel.stringValue) }
        if !timeline.isHidden { lines += timeline.lines }
        if !resourceRow.isHidden { lines.append(resourceRow.shownText) }
        if !customError.isHidden { lines.append(customError.stringValue) }
        return lines + tabList.reportedLines
    }

    /// The name's font, the caption lines' font and the kind icon's frame in the card, as drawn (tests).
    var drawnTitleFont: NSFont? { titleLabel.font }
    var drawnCaptionFont: NSFont? { ageLabel.font }
    var kindIconFrame: CGRect { kindIcon.convert(kindIcon.bounds, to: self) }

    /// The card shows a running time (the status's or a command's): the controller ticks it.
    var isLive: Bool {
        guard detailsExpanded, let content else { return false }
        return (activityWord != nil && content.activitySince != nil) || content.facts.contains { $0.since != nil }
    }

    /// Rewrites the running times for `now` (once a second while the card shows). True when a
    /// text got longer or shorter, so the panel measures the card again.
    @discardableResult
    func tick(now: Date) -> Bool {
        guard let content else { return false }
        var resized = false
        func set(_ label: ChromeLabel, _ text: String) {
            resized = resized || label.stringValue.count != text.count
            label.stringValue = text
        }
        if let word = activityWord {
            set(activityLabel, WorkspaceHoverCardContent.withElapsed(word, since: content.activitySince, now: now))
        }
        for (index, fact) in content.facts.enumerated() where fact.since != nil && index < factViews.count {
            set(factViews[index].textLabel, WorkspaceHoverCardContent.withElapsed(fact.text, since: fact.since, now: now))
        }
        return resized
    }

    func configure(_ content: WorkspaceHoverCardContent, now: Date = Date()) {
        self.content = content
        let host = content.host ?? content.facts.first { $0.kind == "machine" }
        hostLabel.stringValue = host?.text ?? ""
        hostMachine = host?.machine
        hostLabel.isHidden = host == nil
        hostDot.accessory = host?.accessory
        hostDot.isHidden = host?.accessory == nil
        kindIcon.isHidden = host != nil
        applySizes()
        width = content.options.layout == .log ? Self.logCardWidth : widthCap ?? Self.maxCardWidth
        widthLimit?.constant = width
        statsLabel.stringValue = content.stats ?? ""
        statsRow.isHidden = content.stats == nil
        titleLabel.stringValue = content.title
        kindIcon.image = NSImage.icon(content.icon, size: Self.iconSize)
        ageLabel.stringValue = content.age ?? ""
        ageLabel.isHidden = content.age == nil
        activity.configure(content.activity, style: content.activityStyle)
        let word = Strings.activity(content.activity)
        activityWord = word
        activityLabel.stringValue = word.map { WorkspaceHoverCardContent.withElapsed($0, since: content.activitySince, now: now) } ?? ""
        activityRow.isHidden = word == nil
        // The width the title wraps at (the panel sizes the card in one
        // pass): the row less its icon and the age.
        let age = ageLabel.isHidden ? 0 : ageLabel.intrinsicContentSize.width + Metrics.space2
        let icon = kindIcon.isHidden ? 0 : Self.iconSize + Metrics.space2
        let hostWidth = hostLabel.isHidden ? 0 : hostLabel.intrinsicContentSize.width + Metrics.space2
        let dot = hostDot.isHidden ? 0 : hostDot.intrinsicContentSize.width + Metrics.space2
        titleLabel.preferredMaxLayoutWidth = width - 2 * Self.padding - icon - age - hostWidth - dot
        while factViews.count < content.facts.count { addFactRow() }
        let wrap = width - 2 * Self.padding - Self.iconSize - Metrics.space2
        for (index, row) in factViews.enumerated() {
            let fact = index < content.facts.count ? content.facts[index] : nil
            row.isHidden = fact == nil || fact?.kind == "machine"
            guard let fact else { continue }
            var shown = fact.row
            shown.text = WorkspaceHoverCardContent.withElapsed(fact.text, since: fact.since, now: now)
            row.configure(shown, image: Self.ownImage(fact) ?? NSImage.icon(fact.icon, size: Self.iconSize),
                          font: fact.since == nil ? Self.bodyFont : Self.liveFont, wrapWidth: wrap,
                          truncation: Self.truncation(fact))
        }
        // The preview (the last reply or the pull request's state) sits a step apart from the
        // metadata above it, like the stack's own gap.
        for (index, row) in factViews.enumerated() {
            let next = index + 1 < content.facts.count ? content.facts[index + 1] : nil
            factsStack.setCustomSpacing(next?.isPreview == true ? Metrics.space3 : NSStackView.useDefaultSpacing, after: row)
        }
        factsStack.isHidden = !content.facts.contains { $0.kind != "machine" }
        pendingTimelineAt = now
        applyColors()
        updateDetailsVisibility()
    }

    private func toggleDetails() {
        detailsExpanded.toggle()
        updateDetailsVisibility()
        needsLayout = true
        onDetailsChanged?()
    }

    func resetDetails() {
        detailsExpanded = false
        updateDetailsVisibility()
    }

    /// Opens the details without a click (Show Resource Usage asks for them).
    func expandDetails() {
        guard !detailsExpanded else { return }
        detailsExpanded = true
        updateDetailsVisibility()
        needsLayout = true
    }

    /// The tab list and the summary header for `tabs`, as of `now` (their times).
    func configureTabs(title: String, tabs: [SidebarTab], now: Date = Date(), machine: SidebarMachine? = nil) {
        tabList.configure(title: title, tabs: tabs, now: now, machine: machine)
        summaryRow.isHidden = style.header != .summary || tabs.isEmpty
        let running = tabs.filter { $0.state.isWorking || $0.state.isLoading }.count
        let unread = tabs.filter(\.isUnread).count
        summaryLabel.stringValue = [Strings.tabCount(tabs.count), running > 0 ? Strings.hoverCardRunning(running) : nil,
                                    unread > 0 ? Strings.unreadCount(unread) : nil].compactMap { $0 }.joined(separator: " · ")
    }

    /// The tab rows' fill reaches past the content's edges (`WorkspaceTabHoverCardRow.fillOutset`): a point
    /// there belongs to the list, not to the card around it.
    override func hitTest(_ point: NSPoint) -> NSView? {
        if !tabList.isHiddenOrHasHiddenAncestor, let listParent = tabList.superview,
           let hit = tabList.hitTest(listParent.convert(point, from: superview)) {
            return hit
        }
        return super.hitTest(point)
    }

    func acceptsHoverCardMouse(at screenPoint: CGPoint, in panel: NSWindow) -> Bool {
        if tabList.acceptsHoverCardMouse(at: screenPoint, in: panel) { return true }
        let windowPoint = panel.convertPoint(fromScreen: screenPoint)
        let point = superview?.convert(windowPoint, from: nil) ?? windowPoint
        var hit = hitTest(point)
        while let view = hit {
            if view === detailsToggle { return true }
            if view === customSlot, detailsExpanded { return true }
            hit = view.superview
        }
        return false
    }

    private func updateDetailsVisibility() {
        if detailsExpanded, let now = pendingTimelineAt, let content {
            pendingTimelineAt = nil
            if !content.timeline.isEmpty {
                let log = content.options.layout == .log
                timeline.configure(content.timeline, width: width - 2 * Self.padding,
                                   maxHeight: log ? Self.logMaxHeight : Self.timelineMaxHeight, textLines: log ? 3 : 2, now: now)
            }
        }
        detailsToggle.title = detailsExpanded ? Strings.hideDetails : Strings.showDetails
        detailsToggle.isExpanded = detailsExpanded
        if !detailsExpanded {
            for view in builtIn { view.isHidden = true }
            customSlot.isHidden = true
            customError.isHidden = true
        } else if customView != nil {
            for view in builtIn { view.isHidden = true }
            customSlot.isHidden = false
            customError.isHidden = true
        } else {
            customSlot.isHidden = true
            activityRow.isHidden = activityWord == nil
            statsRow.isHidden = content?.stats == nil
            factsStack.isHidden = !(content?.facts.contains(where: { $0.kind != "machine" }) ?? false)
            timeline.isHidden = content?.timeline.isEmpty ?? true
            resourceRow.isHidden = !resourceShown
            customError.isHidden = customError.stringValue.isEmpty
        }
        ageLabel.isHidden = !detailsExpanded || content?.age == nil
        let hasBuiltInDetails = activityWord != nil || content?.age != nil || content?.stats != nil
            || content?.facts.contains(where: { $0.kind != "machine" }) == true || content?.timeline.isEmpty == false || resourceShown
        detailsToggle.isHidden = !hasBuiltInDetails && customView == nil && customError.stringValue.isEmpty
    }

    /// Shows the user's card when it rendered, else the built-in card with the error (if any).
    func setCustom(_ content: (any SidebarCustomContent)?) {
        let ready = content.map { $0.isReady && $0.errorText == nil } ?? false
        if let content, ready, customView !== content.view {
            customView?.removeFromSuperview()
            let view = content.view
            view.translatesAutoresizingMaskIntoConstraints = false
            customSlot.addSubview(view)
            let height = customSlot.heightAnchor.constraint(equalToConstant: 0)
            NSLayoutConstraint.activate([
                view.topAnchor.constraint(equalTo: customSlot.topAnchor),
                view.bottomAnchor.constraint(equalTo: customSlot.bottomAnchor),
                view.leadingAnchor.constraint(equalTo: customSlot.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: customSlot.trailingAnchor),
                customSlot.widthAnchor.constraint(equalToConstant: Self.cardWidth - 2 * Self.padding),
                height,
            ])
            customHeight?.isActive = false
            customHeight = height
            customView = view
        }
        // Wrapped text needs the height at the card's width, measured again on every change.
        if ready, let content { customHeight?.constant = content.preferredHeight(width: Self.cardWidth - 2 * Self.padding) }
        if !ready {
            customView?.removeFromSuperview()
            customView = nil
        }
        customSlot.isHidden = !ready
        for view in builtIn { view.isHidden = ready ? true : view.isHidden }
        if !ready {
            builtIn.first?.isHidden = false
            if let content = self.content { configure(content) }
        }
        resourceRow.isHidden = ready || !resourceShown
        let error = content?.errorText
        customError.stringValue = error.map(Strings.customCardError) ?? ""
        customError.isHidden = error == nil || ready
        updateDetailsVisibility()
        applyColors()
    }

    func setResources(_ report: ResourceReport?) {
        // A redraw hands the same report again; only a new sample adds a bar.
        if let report, report != lastSampled, let cpu = report.total.cpu {
            lastSampled = report
            cpuHistory.append(cpu)
            if cpuHistory.count > HoverCardAccessoryView.maxBars { cpuHistory.removeFirst(cpuHistory.count - HoverCardAccessoryView.maxBars) }
        }
        let row = WorkspaceHoverCardContent.resourceRow(report, history: cpuHistory)
        resourceShown = row != nil
        if let row { resourceRow.configure(row, image: NSImage.icon(.serverHealth, size: Self.iconSize)) }
        updateDetailsVisibility()
    }

    /// The card left its workspace: the next one's bars start empty.
    func resetResourceHistory() {
        cpuHistory.removeAll()
        lastSampled = nil
    }

    private func addFactRow() {
        let row = HoverCardRowView()
        // The card takes its width from its content (cx-k9mc).
        row.textLabel.setContentCompressionResistancePriority(.keepsTextWidth, for: .horizontal)
        factsStack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: factsStack.widthAnchor).isActive = true
        row.iconSide = Self.iconSize
        factViews.append(row)
    }
}

extension WorkspaceHoverCardView {
    var reportedLines: [String] { lines }
}

extension WorkspaceHoverCardView {
    /// Recolors the labels in the card's theme scope; the panel runs it on
    /// adopt and on every change of that scope.
    func applyColors() {
        tabList.applyColors()
        detailsToggle.applyColors()
        performWithTheme {
            // The frosted material (Lawrence msg 19245: glass over a busy terminal was hard to read): a veil of
            // the theme's window background over the glass, below the overlay rule's solid alpha.
            wantsLayer = true
            layer?.cornerRadius = Metrics.panelCornerRadius
            layer?.cornerCurve = .continuous
            // 0.55: as dense as the overlay rule allows a body's tint (under 0.6).
            layer?.backgroundColor = style.material == .frosted ? Palette.windowBackground.withAlphaComponent(0.55).cgColor : nil
            summaryLabel.textColor = Palette.textSecondary
            titleLabel.textColor = Palette.textPrimary
            ageLabel.textColor = Palette.textSecondary
            activityLabel.textColor = Palette.textPrimary
            kindIcon.contentTintColor = Palette.textSecondary
            hostLabel.textColor = hostColor
            statsLabel.textColor = Palette.textSecondary
            timeline.applyColors()
            customError.textColor = Palette.textSecondary
        }
        detailsToggle.needsDisplay = true
        // A clear title, muted metadata, and what was said in the primary ink (Leo 2026-10-19,
        // Claude desktop's session card), each row in its own theme tokens; no fill of its own,
        // the shared overlay glass shows.
        for row in factViews { row.applyColors() }
        resourceRow.applyColors()
        hostDot.applyColors()
    }

    /// The machine's name in its color pick, else the secondary ink like the rest of the header (read in the
    /// card's theme scope).
    private var hostColor: NSColor { hostMachine.flatMap { MachineColor(name: $0).pickedCardTextColor } ?? Palette.textSecondary }

    /// A machine color picked while the card shows reaches the header only through this hook (a store
    /// repaint carries no new theme).
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        performWithTheme { hostLabel.textColor = hostColor }
    }
}
