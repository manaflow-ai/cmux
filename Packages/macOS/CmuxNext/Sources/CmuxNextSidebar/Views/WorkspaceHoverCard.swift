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
    /// Leo 2026-11-07: "this is one of the more important hover previews because it's how we navigate into the thing
    /// and navigate to different tabs. So I don't want it to disappear as quickly as other ones would." By default it
    /// lingers for the leave grace and a pointer heading into it keeps it; Debug Settings
    /// `sidebar.hoverCards.workspaceLeave` brings back hiding at once.
    var leave: HoverCardLeave {
        switch SidebarTunables.workspaceHoverCardLeave.value {
        case .lingers: .lingers
        case .hidesAtOnce: .hides(reshow: HoverCardTiming.reshowWindow)
        }
    }
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
    /// Every card's tab pictures (#51768): a card opened again draws its last at once.
    let thumbnails = SidebarTabThumbnails()
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
    /// The sidebar's rows and owner cards share one card that morphs between them.
    var hoverCardGroup: HoverCardGroup? { .sidebar }

    func hoverCardHit(at screenPoint: CGPoint) -> HoverCardHit? {
        guard let list, let window = list.window else { return nil }
        let windowPoint = window.convertPoint(fromScreen: screenPoint)
        // Under the Updated card's open preview no row or group has a card (`hoverOccluded`).
        if list.hoverOccluded?(windowPoint) == true { return nil }
        let point = list.convert(windowPoint, from: nil)
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
        let windowPoint = window.convertPoint(fromScreen: screenPoint)
        // Under the Updated card's open preview a shown row card bridges nothing: it goes (review F1 of #38117).
        if list.hoverOccluded?(windowPoint) == true { return false }
        let point = list.convert(windowPoint, from: nil)
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
        guard let badge, !badge.isHidden, badge.alphaValue > 0, badge.badge?.items.isEmpty == false
        else { return false }
        return window.convertToScreen(badge.convert(badge.bounds, to: nil)).contains(screenPoint)
    }

    func hoverCardBody(for id: HoverTargetID) -> HoverCardBody? {
        if let group = groupID(id) { return groupCardBody(for: group, id: id) }
        guard let list, let ws = workspaceID(id), let workspace = list.hoverCardRow(ws) else { return nil }
        let body = body ?? WorkspaceHoverCardView()
        body.paneShape.thumbnails = thumbnails
        body.widthCap = min(WorkspaceHoverCardView.maxCardWidth, list.bounds.width + WorkspaceHoverCardView.tokens.sidebarReach)
        if bodyID != id { body.resetDetails() }
        // Activation ran while the card was pending, before this body existed, so details
        // opened here (Show Resource Usage) start their sampling below, once bodyID is set.
        let openedByRequest = detailsRequested == id && !body.isDetailsExpanded
        if openedByRequest { body.expandDetails() }
        self.body = body
        let content = fill(body, with: workspace, ws, in: list)
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
        // A port's row opens it in a browser tab of this workspace, on its machine's localhost (`SidebarIntent.openPort`).
        body.onOpenPort = { [weak self, weak list] url, label in
            guard let self else { return }
            list?.model.send(.openPort(workspace: ws, url: url, label: label))
            self.coordinator.dismiss(.action)
        }
        body.setResources(resources.report)
        bodyID = id
        if openedByRequest { startSampling(id) }
        body.setCustom(customContent(for: ws, id: id, card: content.cardFacts))
        updateTicker()
        return cardBody(body, in: list)
    }

    /// The card body for the first visible workspace row, made and configured as its card would be but not
    /// shown (``HoverCardCoordinator/warm()``): no sampling, ticker, custom card or actions, which a real show sets.
    /// The first hover then reuses it instead of building the card (about 50 ms of the first card's show).
    func hoverCardWarmBody() -> HoverCardBody? {
        guard body == nil, let list,
              let ws = list.displayed.rows.lazy.compactMap({ row -> WorkspaceID? in
                  if case .workspace(let id) = row.key { id } else { nil }
              }).first,
              let workspace = list.hoverCardRow(ws) else { return nil }
        let body = WorkspaceHoverCardView()
        body.paneShape.thumbnails = thumbnails
        body.widthCap = min(WorkspaceHoverCardView.maxCardWidth, list.bounds.width + WorkspaceHoverCardView.tokens.sidebarReach)
        self.body = body
        fill(body, with: workspace, ws, in: list)
        body.setResources(resources.report)
        return cardBody(body, in: list)
    }

    /// Configures `body` with workspace `ws`'s card content (its facts, history and tabs), and returns that content.
    @discardableResult
    private func fill(_ body: WorkspaceHoverCardView, with workspace: SidebarWorkspace, _ ws: WorkspaceID,
                      in list: SidebarListView) -> WorkspaceHoverCardContent {
        let machine = list.sections.values.lazy.compactMap(\.machine).first { $0.id == workspace.machineID }
        let options = DesignSettings.shared.workspaceHoverCard
        let wantsTimeline = options.layout != .classic
        let timeline = wantsTimeline ? (timelineSource?(ws, Self.timelineReadLimit) ?? []) : []
        // The workspace on screen needs no digest: the person is looking at it.
        let looked = ws != list.model.activeWorkspaceID ? SidebarLookedStore.shared.stamps[ws] : nil
        let content = WorkspaceHoverCardContent.make(workspace, machine: machine, now: Date(), options: options, timeline: timeline,
                                                     looked: looked, pullRequests: SidebarSessionTree.shared.pullRequests[ws])
        body.configure(content)
        body.configureTabs(title: ws.rawValue, tabs: workspace.tabs, machine: machine)
        body.configurePaneShape(workspace.paneShape, tabs: workspace.tabs)
        return content
    }

    private func cardBody(_ body: WorkspaceHoverCardView, in list: SidebarListView) -> HoverCardBody {
        HoverCardBody(view: body, placement: .besideRow, themeAnchor: list, interactive: true,
                      cornerRadius: WorkspaceHoverCardView.cardCornerRadius) { [weak body] in body?.applyColors() }
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
        body?.onOpenPort = nil
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
        // Show and Hide details grow and fold the card on the hover cards' motion, not in one jump.
        coordinator.refit(id, animated: true)
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
    /// The card's corners, concentric around its tab rows' fill: a sidebar workspace row's radius (the rows' own)
    /// plus the gap from the card's edge to a row's fill (Lawrence 2026-11-09: "roundness needs to match roundness of
    /// the workspace row itself").
    static var cardCornerRadius: CGFloat {
        SidebarDensityTokens.rowCornerRadius + max(0, padding - WorkspaceTabHoverCardRow.fillOutset)
    }
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
    static var textInset: CGFloat { iconSize + iconGap }
    /// The gap from the icon column to the text, in whole points (``HoverCardRowView/iconGap``): the header's stack
    /// and the frame-laid tab rows then put the text on one pixel.
    static var iconGap: CGFloat { HoverCardRowView.iconGap }
    /// The body font with digits of one width, for lines whose running time ticks.
    private static var liveFont: NSFont { Typography.system(.monospacedDigit, size: tokens.titleSize, weight: .regular) }

    /// When the card's running times next change their text: every second under an hour, then
    /// every minute ("1h 3m"); nil when nothing runs.
    var nextTickDelay: Duration? {
        guard isLive, let content else { return nil }
        let starts = ([content.activitySince] + content.facts.map(\.since)).compactMap { $0 }
        guard let newest = starts.max() else { return nil }
        return Date().timeIntervalSince(newest) < 3600 ? .seconds(1) : .seconds(60) // hover-timing: clock refresh, not a delay
    }

    private let titleLabel = ChromeLabel(labelWithString: "")
    /// The name, its icon, the host and the age (`sidebar.hoverCards.workspaceTitle` hides it when it repeats).
    private let titleRow = NSStackView()
    /// The workspace's tabs' titles, for ``WorkspaceHoverCardTitle/showsTitle(_:tabTitles:expanded:)``.
    private var tabTitles: [String] = []
    /// The kind icon, leading the name on the card's icon column; a Cloud or remote card has none
    /// (its machine reads once, in `hostLabel`).
    private let kindIcon = HoverCardIconView()
    /// The shown screen's splits (ask-890db939a2); hidden for a one-pane workspace.
    let paneShape = WorkspacePaneShapeView()
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
    /// The ports the workspace's terminals serve, one button each, under the tab list with details open or not.
    private let portsStack = NSStackView()
    private(set) var portViews: [WorkspaceHoverCardPortRow] = []
    /// A port row was clicked: its URL and label (the controller opens it in a browser tab of the workspace).
    var onOpenPort: ((_ url: String, _ label: String) -> Void)?
    /// The summary header's line under the name: tab count, running and unread (`style.header`).
    private let summaryLabel = ChromeLabel(labelWithString: "")
    private let summaryRow = NSStackView()
    let style: WorkspaceTabHoverCardStyle
    private var detailsExpanded = false
    var isDetailsExpanded: Bool { detailsExpanded }
    /// Hide details was pressed: the card's next fold may keep the detail rows drawn (`HoverCardFoldingBody`).
    private var foldPending = false
    /// The card folds now with the detail rows still laid out, fading out under its edge.
    private var holdingFold = false
    /// The detail rows are laid out: expanded, or folding from expanded (or the state a measure asks for).
    private var showsDetails: Bool { measuringDetails ?? (detailsExpanded || holdingFold) }
    /// The details state the card is laid out for: the one it is in, or the one a measure asks for (`measure(expanded:)`).
    private var expandedForLayout: Bool { measuringDetails ?? detailsExpanded }
    /// The details state a measure lays the card out for now (`measure(expanded:)`), else nil.
    private var measuringDetails: Bool?
    /// The card's fitting size in each details state (true: expanded) for what it shows now: the panel takes it instead
    /// of measuring (`HoverCardSizeReporting`). Any change of what the card shows empties it (`contentChanged`).
    private var sizeCache: [Bool: CGSize] = [:]
    /// Measures the card ran itself (`fittingSize`, a temporary layout engine each): tests count them.
    private(set) var selfMeasures = 0
    /// Times shown detail rows were hidden (not by a measure): tests count them.
    private(set) var detailRowsHidings = 0
    var onDetailsChanged: (() -> Void)?
    /// Presses of Show details or Hide details not run yet: they run at the start of the card window's next frame.
    private var pendingDetailsPresses = 0
    private lazy var detailsPressFrame = DetailsPressFrame(card: self)
    /// The scrollable history of prompts, waits and finished turns (u3320).
    let timeline = WorkspaceHoverCardTimelineView()
    /// The card's widest; the full history layout widens it.
    private var widthLimit: NSLayoutConstraint?
    private var width: CGFloat = WorkspaceHoverCardView.cardWidth
    /// The constraints the tokens size, and how (`applySizes`).
    private var sized: [(NSLayoutConstraint, (SidebarHoverCardMetrics) -> CGFloat)] = []
    /// The rows, and their top and bottom insets from the card's edges (`applyEdgeInsets`).
    private var rowsStack: NSStackView?
    private var topInset: NSLayoutConstraint?
    private var bottomInset: NSLayoutConstraint?
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
        detailsToggle.onPress = { [weak self] in self?.pressDetails() }

        // Every icon sits on one column at the leading inset, its text beside it (the fact rows'
        // grid), so the kind icon leads the name instead of floating after it.
        titleRow.setViews([kindIcon, titleLabel, hostDot, hostLabel], in: .leading)
        titleRow.setViews([ageLabel], in: .trailing)
        titleRow.orientation = .horizontal
        titleRow.alignment = .firstBaseline
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
        var rows: [NSView] = [customSlot, titleRow, paneShape, summaryRow, activityRow, statsRow, factsStack, timeline, resourceRow, customError]
        let tabIndex = tabPlacement == .afterTitle ? 4 : (tabPlacement == .afterStatus ? 6 : 10)
        rows.insert(tabList, at: tabIndex)
        rows.insert(portsStack, at: tabIndex + 1)
        rows.insert(detailsToggle, at: tabIndex + 2)
        portsStack.orientation = .vertical
        portsStack.alignment = .leading
        portsStack.spacing = 0
        portsStack.isHidden = true
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        // The shared hover card style's one spacing scale (`HoverCardStyle`), as every other hover card.
        stack.spacing = HoverCardStyle.shared.rowGap
        // Show details reads as the list's last row, on the rows' spacing.
        stack.setCustomSpacing(Metrics.space1, after: tabList)
        stack.setCustomSpacing(Metrics.space1, after: titleRow)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        let widthLimit = content.widthAnchor.constraint(lessThanOrEqualToConstant: Self.cardWidth)
        self.widthLimit = widthLimit
        let topInset = stack.topAnchor.constraint(equalTo: content.topAnchor, constant: Self.padding)
        let bottomInset = content.bottomAnchor.constraint(equalTo: stack.bottomAnchor, constant: Self.padding)
        (rowsStack, self.topInset, self.bottomInset) = (stack, topInset, bottomInset)
        sized = [
            (content.widthAnchor.constraint(greaterThanOrEqualToConstant: Self.minCardWidth), \.minWidth),
            (stack.leadingAnchor.constraint(equalTo: content.leadingAnchor), \.padding),
            (stack.trailingAnchor.constraint(equalTo: content.trailingAnchor), { -$0.padding }),
        ] + [kindIcon.widthAnchor, kindIcon.heightAnchor, activitySlot.widthAnchor, activitySlot.heightAnchor,
             activity.widthAnchor, activity.heightAnchor].map { ($0.constraint(equalToConstant: Self.iconSize), \.iconSide) }
        NSLayoutConstraint.activate(sized.map(\.0) + [
            widthLimit,
            topInset,
            bottomInset,
            timeline.widthAnchor.constraint(equalTo: stack.widthAnchor),
            tabList.widthAnchor.constraint(equalTo: stack.widthAnchor),
            detailsToggle.widthAnchor.constraint(equalTo: stack.widthAnchor),
            portsStack.widthAnchor.constraint(equalTo: stack.widthAnchor),
            titleRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            paneShape.widthAnchor.constraint(equalTo: stack.widthAnchor),
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
        titleRow.spacing = Self.iconGap
        activityRow.spacing = Self.iconGap
        activitySlot?.side = tokens.iconSide
        statsRow.edgeInsets = NSEdgeInsets(top: 0, left: Self.textInset, bottom: 0, right: 0)
        summaryRow.edgeInsets = NSEdgeInsets(top: 0, left: Self.textInset, bottom: 0, right: 0)
        for (constraint, value) in sized { constraint.constant = value(tokens) }
        resourceRow.iconSide = tokens.iconSide
        factViews.forEach { $0.iconSide = tokens.iconSide }
        detailsToggle.applySizes()
        applyEdgeInsets()
    }

    /// A tab row's fill and Show details' reach `WorkspaceTabHoverCardRow.fillOutset` past the rows' sides; where one
    /// is the first or the last row shown, the rows come that much nearer the card's top or bottom too, so the fill
    /// stands one gap from every edge it meets, the gap the card's corners are concentric around (Lawrence
    /// 2026-11-16: "bottom padding must be same as left/right, same for top"). A row with no fill keeps the padding.
    private func applyEdgeInsets() {
        guard let rowsStack else { return }
        let shown = rowsStack.arrangedSubviews.filter { !$0.isHidden }
        // Read once: the tokens are worked out from the density settings on each read.
        let padding = Self.padding
        func inset(_ edge: NSView?) -> CGFloat {
            let fills = edge === tabList || edge === detailsToggle
            return padding - (fills ? WorkspaceTabHoverCardRow.fillOutset : 0)
        }
        topInset?.constant = inset(shown.first)
        bottomInset?.constant = inset(shown.last)
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
        return lines + tabList.reportedLines + portViews.filter { !$0.isHidden }.map(\.row.shownText)
    }

    /// The name's font, the caption lines' font and the kind icon's frame in the card, as drawn (tests).
    var drawnTitleFont: NSFont? { titleLabel.font }
    /// The name row is hidden (`sidebar.hoverCards.workspaceTitle`; tests read it).
    var drawnTitleHidden: Bool { titleLabel.isHidden }
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
        if resized { contentChanged() }
        return resized
    }

    func configure(_ content: WorkspaceHoverCardContent, now: Date = Date()) {
        contentChanged()
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
        let age = ageLabel.isHidden ? 0 : ageLabel.intrinsicContentSize.width + Self.iconGap
        let icon = kindIcon.isHidden ? 0 : Self.iconSize + Self.iconGap
        let hostWidth = hostLabel.isHidden ? 0 : hostLabel.intrinsicContentSize.width + Self.iconGap
        let dot = hostDot.isHidden ? 0 : hostDot.intrinsicContentSize.width + Self.iconGap
        titleLabel.preferredMaxLayoutWidth = width - 2 * Self.padding - icon - age - hostWidth - dot
        while factViews.count < content.facts.count { addFactRow() }
        let wrap = width - 2 * Self.padding - Self.textInset
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
        configurePorts(content.ports)
        pendingTimelineAt = now
        applyColors()
        updateDetailsVisibility()
    }

    /// A press of Show details or Hide details runs at the start of the card window's next frame, as Android runs input
    /// (Choreographer's input callbacks) and Chrome its continuous input: the card's layout, its measure and the first
    /// frame of its resize are a few ms of main-thread work, and run at once from a press that came at any point in a
    /// frame they crossed its end on most presses (36 to 37 of 40 on cmux-lawrence-2 at 120 Hz, Lawrence 2026-11-18:
    /// a display frame skipped). At the frame's start they fit in it. The card shows the change on the same frame it did
    /// when the work crossed that end. Reduce Motion, speed off or a card in no window: at once.
    private func pressDetails() {
        pendingDetailsPresses += 1
        guard let window, Motion.hoverCards.animatesMovement(in: window) else { return runPendingDetailsPresses() }
        MotionClock.forWindow(window).run(detailsPressFrame, trace: "hoverCard.detailsPress")
    }

    /// Runs the presses not run yet (the frame's start; tests call it after a press). Two presses before one frame
    /// change nothing.
    func runPendingDetailsPresses() {
        let presses = pendingDetailsPresses
        pendingDetailsPresses = 0
        if presses % 2 == 1 { toggleDetails() }
    }

    private func toggleDetails() {
        detailsExpanded.toggle()
        foldPending = !detailsExpanded
        // Hide details that will fold keeps its rows laid out from the start (the fold holds them), instead of hiding
        // them here and showing them again when the fold takes them (`holdLayoutWhileFolding`).
        if foldPending, let window, Motion.hoverCards.animatesMovement(in: window) { holdingFold = true }
        updateDetailsVisibility()
        needsLayout = true
        // Show details: the rows fade in as the card grows over them (the card's growth reveals them,
        // the fade keeps their text from being cut mid-line by the moving edge at full strength).
        if detailsExpanded { fadeDetails(in: true) }
        onDetailsChanged?()
        // No fold took the rows (no resize ran): they go now.
        if foldPending, holdingFold {
            holdingFold = false
            updateDetailsVisibility()
        }
        foldPending = false
    }

    /// What the card shows changed: its sizes are measured again.
    private func contentChanged() { sizeCache.removeAll() }

    /// The card's fitting size laid out for `expanded` (the details state), with the state it is in kept: a measure of
    /// the other state lays the rows out for it, measures, and puts them back, with no layout pass between.
    private func measure(expanded: Bool) -> CGSize {
        selfMeasures += 1
        guard expanded != showsDetails || expanded != detailsExpanded else { return fittingSize }
        measuringDetails = expanded
        updateDetailsVisibility()
        let size = fittingSize
        measuringDetails = nil
        updateDetailsVisibility()
        return size
    }

    func resetDetails() {
        pendingDetailsPresses = 0
        detailsExpanded = false
        foldPending = false
        holdingFold = false
        restoreDetailsOpacity()
        updateDetailsVisibility()
    }

    /// The detail rows shown now (the built-in ones or the customization's).
    private var detailViews: [NSView] {
        (builtIn + [customSlot, customError]).filter { !$0.isHidden }
    }

    /// The detail rows fade in (`in`: Show details) or out (a fold): the hover cards' fades, so
    /// Reduce Motion and speed off apply. Opacity only: the card's resize carries the movement.
    private func fadeDetails(in fadesIn: Bool) {
        for view in detailViews {
            view.wantsLayer = true
            guard let layer = view.layer else { continue }
            if fadesIn {
                Motion.hoverCards.set(layer, "opacity", to: Float(1), fade: .fadeIn, from: Float(0))
            } else {
                Motion.hoverCards.set(layer, "opacity", to: Float(0), fade: .fadeOut, from: Float(1))
            }
        }
    }

    /// Every detail row whole again (the next Show details starts from a whole row).
    private func restoreDetailsOpacity() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for view in builtIn + [customSlot, customError] {
            guard let layer = view.layer else { continue }
            layer.removeAnimation(forKey: "opacity")
            layer.opacity = 1
        }
        CATransaction.commit()
    }

    /// Opens the details without a click (Show Resource Usage asks for them).
    func expandDetails() {
        guard !detailsExpanded else { return }
        detailsExpanded = true
        updateDetailsVisibility()
        needsLayout = true
    }

    /// The tab list and the summary header for `tabs`, as of `now` (their times).
    /// Shows `shape`, the workspace's splits, under the title; nil hides the miniature.
    /// Each show asks for the tiles' newest pictures (#51768); the last ones draw meanwhile.
    /// `tabs` name the tiles that have no picture yet (``WorkspacePaneShapeView/label(for:)``).
    func configurePaneShape(_ shape: SidebarPaneShape?, tabs: [SidebarTab] = []) {
        paneShape.labels = Dictionary(tabs.map { ($0.id, WorkspacePaneShapeView.label(for: $0)) }, uniquingKeysWith: { first, _ in first })
        if paneShape.shape != shape {
            contentChanged()
            paneShape.shape = shape
        }
        paneShape.refreshThumbnails()
    }

    func configureTabs(title: String, tabs: [SidebarTab], now: Date = Date(), machine: SidebarMachine? = nil) {
        contentChanged()
        tabList.configure(title: title, tabs: tabs, now: now, machine: machine)
        tabTitles = tabs.map(\.title)
        updateTitleVisibility()
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
            if view === detailsToggle || view is WorkspaceHoverCardPortRow { return true }
            if view === customSlot, detailsExpanded { return true }
            hit = view.superview
        }
        return false
    }

    private func updateDetailsVisibility() {
        if expandedForLayout, let now = pendingTimelineAt, let content {
            pendingTimelineAt = nil
            if !content.timeline.isEmpty {
                let log = content.options.layout == .log
                timeline.configure(content.timeline, width: width - 2 * Self.padding,
                                   maxHeight: log ? Self.logMaxHeight : Self.timelineMaxHeight, textLines: log ? 3 : 2, now: now)
            }
        }
        detailsToggle.title = expandedForLayout ? Strings.hideDetails : Strings.showDetails
        detailsToggle.isExpanded = expandedForLayout
        if !showsDetails {
            if measuringDetails == nil, builtIn.contains(where: { !$0.isHidden }) { detailRowsHidings += 1 }
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
        ageLabel.isHidden = !showsDetails || content?.age == nil
        updateTitleVisibility()
        let hasBuiltInDetails = activityWord != nil || content?.age != nil || content?.stats != nil
            || content?.facts.contains(where: { $0.kind != "machine" }) == true || content?.timeline.isEmpty == false || resourceShown
        detailsToggle.isHidden = !hasBuiltInDetails && customView == nil && customError.stringValue.isEmpty
        applyEdgeInsets()
    }

    /// The name row shows unless the tab rows already say it (`sidebar.hoverCards.workspaceTitle`): a host shown
    /// beside the name keeps the row, since the tabs do not say where the workspace runs.
    private func updateTitleVisibility() {
        guard let content else { return }
        let shows = SidebarTunables.workspaceHoverCardTitle.value.showsTitle(content.title, tabTitles: tabTitles, expanded: showsDetails)
        titleRow.isHidden = !shows && hostLabel.isHidden
        titleLabel.isHidden = !shows
        kindIcon.isHidden = !shows || !hostLabel.isHidden
        applyEdgeInsets()
    }

    /// Shows the user's card when it rendered, else the built-in card with the error (if any).
    func setCustom(_ content: (any SidebarCustomContent)?) {
        contentChanged()
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
        contentChanged()
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

    /// One button per port (`WorkspaceHoverCardContent.ports`), reused card to card; none hides the stack.
    private func configurePorts(_ ports: [WorkspaceHoverCardContent.Fact]) {
        while portViews.count < ports.count {
            let row = WorkspaceHoverCardPortRow()
            portsStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: portsStack.widthAnchor).isActive = true
            portViews.append(row)
        }
        for (index, row) in portViews.enumerated() {
            let fact = index < ports.count ? ports[index] : nil
            row.isHidden = fact == nil
            guard let fact else { continue }
            row.configure(fact, image: NSImage.icon(fact.icon, size: Self.iconSize), font: Self.bodyFont, iconSide: Self.iconSize)
            row.onPress = { [weak self] in
                guard let url = fact.link else { return }
                self?.onOpenPort?(url, fact.text)
            }
        }
        portsStack.isHidden = ports.isEmpty
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

/// Hide details folds the card over its detail rows: they stay laid out, fading out, while the card's edge
/// folds up to the toggle, and go when the fold ends (msg 38370: the rows went at once and an empty card
/// folded after them).
extension WorkspaceHoverCardView: HoverCardFoldingBody {
    func holdLayoutWhileFolding() -> Bool {
        guard foldPending, !detailsExpanded else { return false }
        foldPending = false
        if !holdingFold {
            holdingFold = true
            updateDetailsVisibility()
        }
        fadeDetails(in: false)
        return true
    }

    func endFoldHold() {
        guard holdingFold else { return }
        holdingFold = false
        updateDetailsVisibility()
        restoreDetailsOpacity()
    }
}

extension WorkspaceHoverCardView {
    var reportedLines: [String] { lines }
}

/// The card's own size for the details state it is in: a Show details or Hide details press resizes the card without a
/// measure (a temporary layout engine, most of the press's main-thread work), from sizes measured while it rested.
/// A card that shows the user's own view measures each time (that view sizes itself).
extension WorkspaceHoverCardView: HoverCardSizeReporting {
    var reportedFittingSize: CGSize? {
        guard customView == nil, customError.stringValue.isEmpty else { return nil }
        if let size = sizeCache[detailsExpanded] { return size }
        let size = measure(expanded: detailsExpanded)
        sizeCache[detailsExpanded] = size
        return size
    }

    func prepareSizes() {
        guard customView == nil, customError.stringValue.isEmpty else { return }
        for expanded in [detailsExpanded, !detailsExpanded] where sizeCache[expanded] == nil {
            // The other state only when the card can change to it (it has Show details).
            if expanded != detailsExpanded, detailsToggle.isHidden { continue }
            sizeCache[expanded] = measure(expanded: expanded)
        }
    }
}

extension WorkspaceHoverCardView {
    /// Recolors the labels in the card's theme scope; the panel runs it on
    /// adopt and on every change of that scope.
    func applyColors() {
        tabList.applyColors()
        detailsToggle.applyColors()
        paneShape.applyColors()
        performWithTheme {
            // The frosted material (Lawrence msg 19245: glass over a busy terminal was hard to read): a veil of
            // the theme's window background over the glass, below the overlay rule's solid alpha.
            wantsLayer = true
            layer?.cornerRadius = Self.cardCornerRadius
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
        for row in portViews { row.applyColors() }
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

/// The start of the card window's next frame, for a press of Show details or Hide details
/// (``WorkspaceHoverCardView/runPendingDetailsPresses()``): one step, then rest.
private final class DetailsPressFrame: MotionAnimating {
    weak var card: WorkspaceHoverCardView?
    init(card: WorkspaceHoverCardView) { self.card = card }
    func motionStep(_ dt: Double) -> Bool {
        card?.runPendingDetailsPresses()
        return false
    }
    func motionSettle() { card?.runPendingDetailsPresses() }
}
