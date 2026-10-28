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
/// Resources are sampled from hover start (the CPU baseline) until the
/// card hides; nothing is sampled while no card is pending or shown.
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
    /// its row's top, one device pixel off the sidebar's edge (`HoverCardPlacement.besideRow`).
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
        guard let id = coordinator.machine.shownTarget?.id, let ws = workspaceID(id), list?.workspaces[ws] != nil else { return nil }
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
        // The row's band across the sidebar: the card's top on the row's, one pixel off the edge.
        if let group = groupID(id) { return list?.hoverCardBand(forGroup: group) }
        return workspaceID(id).flatMap { list?.hoverCardBand(for: $0) }
    }

    func hoverCardTargetFrame(for id: HoverTargetID) -> CGRect? {
        if let group = groupID(id) { return list?.hoverCardAnchor(forGroup: group) }
        return workspaceID(id).flatMap { list?.hoverCardAnchor(for: $0) }
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
        guard let list, let ws = workspaceID(id), let workspace = list.workspaces[ws] else { return nil }
        let body = body ?? WorkspaceHoverCardView()
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
        body.setResources(resources.report)
        bodyID = id
        body.setCustom(customContent(for: ws, id: id, card: content.cardFacts))
        updateTicker()
        return HoverCardBody(view: body, placement: .besideRow, themeAnchor: list) { [weak body] in body?.applyColors() }
    }

    /// A group header's summary card (`GroupHoverCardSummary`): no sampling, no ticker.
    private func groupCardBody(for group: GroupID, id: HoverTargetID) -> HoverCardBody? {
        guard let list, let item = list.groups[group] else { return nil }
        let body = groupBody ?? GroupHoverCardView()
        groupBody = body
        body.configure(Self.groupSummary(item, workspaces: list.subtreeWorkspaces(of: group),
                                         options: DesignSettings.shared.groupHoverCard, now: Date()))
        bodyID = id
        // One rule for sidebar cards: beside the sidebar, its top on the header's, one pixel off the edge.
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
        guard let ws = workspaceID(id) else { return }
        resources.open(.workspace(ws.rawValue)) { [weak self] report in
            guard let self, self.bodyID == id else { return }
            self.body?.setResources(report)
            self.coordinator.contentChanged(id)
        }
    }

    func hoverCardDeactivated(_ id: HoverTargetID) {
        resources.close()
        body?.resetResourceHistory()
        bodyID = nil
        releaseCustom()
        updateTicker()
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
final class WorkspaceHoverCardView: NSView {
    private static var padding: CGFloat { Metrics.space4 }
    /// The card sizes to its content between these widths (POLISH: no
    /// blank band beside a short name); a long name wraps at the widest.
    static var cardWidth: CGFloat { 280 }
    static var minCardWidth: CGFloat { 180 }
    /// The full history layout's width: a prompt reads in longer lines (u3320).
    static var logCardWidth: CGFloat { 340 }
    /// How tall the history may grow before it scrolls: the default card, and the full history.
    static var timelineMaxHeight: CGFloat { 220 }
    static var logMaxHeight: CGFloat { 360 }
    private static var iconSize: CGFloat { HoverCardRowView.iconSize }
    /// Where every row's text starts, past the icon column: the name, the status word, the
    /// stats and each fact share this one leading edge.
    static var textInset: CGFloat { iconSize + Metrics.space2 }
    /// The body font with digits of one width, for lines whose running time ticks.
    private static var liveFont: NSFont { Typography.system(.monospacedDigit, size: Typography.body.pointSize, weight: .regular) }

    /// When the card's running times next change their text: every second under an hour, then
    /// every minute ("1h 3m"); nil when nothing runs.
    var nextTickDelay: Duration? {
        guard isLive, let content else { return nil }
        let starts = ([content.activitySince] + content.facts.map(\.since)).compactMap { $0 }
        guard let newest = starts.max() else { return nil }
        return Date().timeIntervalSince(newest) < 3600 ? .seconds(1) : .seconds(60)
    }

    private let titleLabel = ChromeLabel(labelWithString: "")
    /// The kind or host icon, leading the name on the card's icon column.
    private let kindIcon = HoverCardIconView()
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
    /// The scrollable history of prompts, waits and finished turns (u3320).
    let timeline = WorkspaceHoverCardTimelineView()
    /// The card's widest; the full history layout widens it.
    private var widthLimit: NSLayoutConstraint?
    private var width: CGFloat = WorkspaceHoverCardView.cardWidth
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
    /// The shown status word, before its elapsed time.
    private var activityWord: String?

    init() {
        super.init(frame: .zero)
        let content = self
        titleLabel.font = Typography.bodyEmphasized
        // The whole name, wrapped: the card is where a clipped row title
        // reads in full (also under Reduce Motion, which has no marquee).
        titleLabel.lineBreakMode = .byWordWrapping
        titleLabel.maximumNumberOfLines = 6
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        ageLabel.font = Typography.caption
        ageLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        ageLabel.setContentHuggingPriority(.required, for: .horizontal)
        kindIcon.setContentHuggingPriority(.required, for: .horizontal)
        kindIcon.line = titleLabel
        kindIcon.side = Self.iconSize
        // Digits of one width: a running time that ticks keeps its width ("1m 11s", "1m 18s").
        activityLabel.font = Self.liveFont
        activityLabel.lineBreakMode = .byTruncatingTail
        resourceRow.isHidden = true
        statsLabel.font = Typography.system(.monospacedDigit, size: Typography.caption.pointSize, weight: .regular)
        statsLabel.lineBreakMode = .byTruncatingTail
        timeline.isHidden = true

        // Every icon sits on one column at the leading inset, its text beside it (the fact rows'
        // grid), so the kind icon leads the name instead of floating after it.
        let titleRow = NSStackView(views: [kindIcon, titleLabel, ageLabel])
        titleRow.orientation = .horizontal
        titleRow.alignment = .firstBaseline
        titleRow.spacing = Metrics.space2
        titleRow.setCustomSpacing(Metrics.space4, after: titleLabel)
        // The indicator's slot is a box that never hides, so a style that draws no glyph keeps the
        // word on the text column.
        let activitySlot = HoverCardIconSlot(side: Self.iconSize, line: activityLabel)
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

        customError.font = Typography.caption
        customError.maximumNumberOfLines = 3
        customError.isHidden = true
        customSlot.isHidden = true
        // The stats line reads on the text column with the name and the facts, not under the icons.
        statsRow.setViews([statsLabel], in: .leading)
        statsRow.edgeInsets = NSEdgeInsets(top: 0, left: Self.textInset, bottom: 0, right: 0)
        statsRow.isHidden = true
        builtIn = [titleRow, activityRow, statsRow, factsStack, timeline, resourceRow]
        let stack = NSStackView(views: [customSlot, titleRow, activityRow, statsRow, factsStack, timeline, resourceRow, customError])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Metrics.space3
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        let p = Self.padding
        let widthLimit = content.widthAnchor.constraint(lessThanOrEqualToConstant: Self.cardWidth)
        self.widthLimit = widthLimit
        NSLayoutConstraint.activate([
            widthLimit,
            timeline.widthAnchor.constraint(equalTo: stack.widthAnchor),
            content.widthAnchor.constraint(greaterThanOrEqualToConstant: Self.minCardWidth),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: p),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -p),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: p),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -p),
            titleRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            factsStack.widthAnchor.constraint(equalTo: stack.widthAnchor),
            resourceRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            kindIcon.widthAnchor.constraint(equalToConstant: Self.iconSize),
            kindIcon.heightAnchor.constraint(equalToConstant: Self.iconSize),
            activitySlot.widthAnchor.constraint(equalToConstant: Self.iconSize),
            activitySlot.heightAnchor.constraint(equalToConstant: Self.iconSize),
            activity.widthAnchor.constraint(equalToConstant: Self.iconSize),
            activity.heightAnchor.constraint(equalToConstant: Self.iconSize),
            activity.centerXAnchor.constraint(equalTo: activitySlot.centerXAnchor),
            activity.centerYAnchor.constraint(equalTo: activitySlot.centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The text the card shows, one entry per row (tests, accessibility).
    var lines: [String] {
        if !customSlot.isHidden { return ["custom card"] + Self.texts(in: customSlot) }
        var lines = [[titleLabel.stringValue, ageLabel.isHidden ? "" : ageLabel.stringValue]
            .filter { !$0.isEmpty }.joined(separator: " ")]
        if !activityRow.isHidden { lines.append(activityLabel.stringValue) }
        if !statsRow.isHidden { lines.append(statsLabel.stringValue) }
        lines += factViews.filter { !$0.isHidden }.map(\.shownText)
        if !timeline.isHidden { lines += timeline.lines }
        if !resourceRow.isHidden { lines.append(resourceRow.shownText) }
        if !customError.isHidden { lines.append(customError.stringValue) }
        return lines
    }

    /// The card shows a running time (the status's or a command's): the controller ticks it.
    var isLive: Bool {
        guard let content else { return false }
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
        width = content.options.layout == .log ? Self.logCardWidth : Self.cardWidth
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
        let age = ageLabel.isHidden ? 0 : ageLabel.intrinsicContentSize.width + Metrics.space4
        titleLabel.preferredMaxLayoutWidth = width - 2 * Self.padding - Self.iconSize - Metrics.space2 - age
        while factViews.count < content.facts.count { addFactRow() }
        let wrap = width - 2 * Self.padding - Self.iconSize - Metrics.space2
        for (index, row) in factViews.enumerated() {
            let fact = index < content.facts.count ? content.facts[index] : nil
            row.isHidden = fact == nil
            guard let fact else { continue }
            var shown = fact.row
            shown.text = WorkspaceHoverCardContent.withElapsed(fact.text, since: fact.since, now: now)
            row.configure(shown, image: Self.ownImage(fact) ?? NSImage.icon(fact.icon, size: Self.iconSize),
                          font: fact.since == nil ? Typography.body : Self.liveFont, wrapWidth: wrap,
                          truncation: Self.truncation(fact))
        }
        // The preview (the last reply or the pull request's state) sits a step apart from the
        // metadata above it, like the stack's own gap.
        for (index, row) in factViews.enumerated() {
            let next = index + 1 < content.facts.count ? content.facts[index + 1] : nil
            factsStack.setCustomSpacing(next?.isPreview == true ? Metrics.space3 : NSStackView.useDefaultSpacing, after: row)
        }
        factsStack.isHidden = content.facts.isEmpty
        let log = content.options.layout == .log
        timeline.isHidden = content.timeline.isEmpty
        if !content.timeline.isEmpty {
            timeline.configure(content.timeline, width: width - 2 * Self.padding,
                               maxHeight: log ? Self.logMaxHeight : Self.timelineMaxHeight, textLines: log ? 3 : 2, now: now)
        }
        applyColors()
    }

    /// Every text an embedded view shows, by its accessibility (a SwiftUI scene has no labels).
    /// Depth first, a parent before its children, children in order. An explicit stack, not a
    /// recursive local function: Swift 6.3.3's SendNonSendable pass crashed now and then on the
    /// local function's capture of the result (Release compile, CmuxNextSidebar).
    private static func texts(in view: NSView) -> [String] {
        var out: [String] = []
        var pending: [Any] = [view]
        while let element = pending.popLast() {
            guard let object = element as? any NSAccessibilityProtocol else { continue }
            if let role = object.accessibilityRole(), role == .staticText,
               let value = object.accessibilityValue() as? String ?? object.accessibilityLabel(), !value.isEmpty {
                out.append(value)
            }
            // Reversed, so the first child pops first.
            pending.append(contentsOf: (object.accessibilityChildren() ?? []).reversed())
        }
        return out
    }

    /// Where a one-line fact cuts: a path or a branch in the middle (its end says which), a pull
    /// request at its tail ("#22231 Share one hover…": the number and the title's start read).
    static func truncation(_ fact: WorkspaceHoverCardContent.Fact) -> NSLineBreakMode {
        fact.kind == "pullRequest" ? .byTruncatingTail : .byTruncatingMiddle
    }

    /// A status entry's own icon: its stored image, its SF Symbol or its emoji; nil for none (or
    /// an asset not read yet), so the fact's icon draws.
    private static func ownImage(_ fact: WorkspaceHoverCardContent.Fact) -> NSImage? {
        let size = NSSize(width: iconSize, height: iconSize)
        if let image = fact.image { return NSImage(cgImage: image.image, size: size) }
        guard let mark = fact.mark, !mark.isEmpty else { return nil }
        if let symbol = NSImage(systemSymbolName: mark, accessibilityDescription: nil) { return symbol }
        guard !mark.unicodeScalars.allSatisfy(\.isASCII) else { return nil }
        return NSImage(size: size, flipped: false) { rect in
            (mark as NSString).draw(in: rect, withAttributes: [.font: Typography.system(size: rect.height * 0.8)])
            return true
        }
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
        resourceRow.isHidden = row == nil || !customSlot.isHidden
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
        factViews.append(row)
    }
}

extension WorkspaceHoverCardView: HoverCardTextReporting {
    var reportedLines: [String] { lines }
}

extension WorkspaceHoverCardView {
    /// Recolors the labels in the card's theme scope; the panel runs it on
    /// adopt and on every change of that scope.
    func applyColors() {
        performWithTheme {
            titleLabel.textColor = Palette.textPrimary
            ageLabel.textColor = Palette.textSecondary
            activityLabel.textColor = Palette.textPrimary
            kindIcon.contentTintColor = Palette.textSecondary
            statsLabel.textColor = Palette.textSecondary
            timeline.applyColors()
            customError.textColor = Palette.textSecondary
        }
        // A clear title, muted metadata, and what was said in the primary ink (Leo 2026-10-19,
        // Claude desktop's session card), each row in its own theme tokens; no fill of its own,
        // the shared overlay glass shows.
        for row in factViews { row.applyColors() }
        resourceRow.applyColors()
    }
}
