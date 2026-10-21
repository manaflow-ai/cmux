import CmuxNextDesign
import CmuxNextIcons
import CmuxNextResources
import Foundation

/// What the workspace hover card says (Leo 2026-10-08, Codex parity): a
/// title row (the name, a kind or host icon, the relative age) and one row
/// per meaningful fact, each with an icon: folder, branch, pull request,
/// computer, the agent working there (cx-13w3), and each reported status entry with its own
/// icon (cx-qno.11.1), then an agent chat's last reply. CPU and memory show as one line, and
/// only when notable.
struct WorkspaceHoverCardContent: Equatable {
    struct Fact: Equatable {
        var icon: IconName
        var text: String
        /// A status entry's own icon (an SF Symbol name or one emoji), drawn instead of `icon`.
        var mark: String?
        /// A status entry's stored image or SVG, drawn instead of both.
        var image: SidebarFavicon?
        /// A running fact's start: the card appends how long it has run, live.
        var since: Date?
        /// How many lines the text may wrap to (a task or a waiting reason reads in full).
        var lines: Int = 1
        /// The field it shows (`SidebarCardFacts.Fact.kind`), for a custom card.
        var kind = "status"
        /// A colored word ahead of the text (a pull request's "Merged" or "Conflict").
        var status: String?
        var statusTone: HoverCardTone = .secondary
        /// A pull request's added and removed lines.
        var additions: Int?
        var deletions: Int?
        /// The trailing mark: a machine's online dot, a context ring.
        var accessory: HoverCardAccessory?
        /// The text's own ink, over the message or metadata ink (an offline machine's warning).
        var ink: HoverCardTone?

        /// The row the shared hover card row draws (`HoverCardRowView`).
        var row: HoverCardRowContent {
            HoverCardRowContent(text: text, ink: ink ?? (isMessage ? .primary : .secondary), lines: lines, status: status,
                                statusTone: statusTone, additions: additions, deletions: deletions, accessory: accessory)
        }

        /// What someone said or asked (a waiting reason, a notification, the task, the last
        /// reply): it reads in the primary ink. Every other row is metadata in the secondary ink,
        /// under the title (Claude desktop's session card: a title, muted metadata, the message).
        var isMessage: Bool { Self.messageKinds.contains(kind) }
        static let messageKinds: Set<String> = ["needsInput", "notification", "task", "description", lastReplyKind]
        /// The agent chat's last reply, the card's last line.
        static let lastReplyKind = "lastReply"
    }

    var title: String
    var icon: IconName
    /// How long ago the workspace was last active ("4w"); nil without activity.
    var age: String?
    var facts: [Fact]
    /// The workspace's merged status and its style hint (the row's indicator).
    var activity: StatusIndicatorState = .idle
    var activityStyle: StatusIndicatorStyle?
    /// When that status began; the status row appends how long it has held, live (cx-swovq).
    var activitySince: Date?
    /// The history lines the card lists, newest first (u3320), filtered by the options.
    var timeline: [SidebarTimelineEntry] = []
    /// The stats line under the status ("Prompts: 4 · Worked 12m"); nil when hidden or empty.
    var stats: String?
    /// The options the card was made with (its layout picks the card's width and history height).
    var options = WorkspaceHoverCardOptions()

    /// CPU of at least half a core, or memory of at least 1 GB, is worth a line.
    static let notableCPU = 0.5
    static let notableMemoryBytes: UInt64 = 1 << 30
    /// The card lists this many checklist items, then how many more.
    static let visibleChecklistLimit = 6

    /// The card for `workspace` with the default options and no history (the classic card's facts).
    static func make(_ workspace: SidebarWorkspace, machine: SidebarMachine?, now: Date) -> Self {
        make(workspace, machine: machine, now: now, options: { var o = WorkspaceHoverCardOptions(); o.layout = .classic; return o }(), timeline: [])
    }

    /// The card for `workspace` as `options` lay it out (u3320), with its `timeline` (newest first).
    static func make(_ workspace: SidebarWorkspace, machine: SidebarMachine?, now: Date,
                     options: WorkspaceHoverCardOptions, timeline: [SidebarTimelineEntry]) -> Self {
        var card = facts(workspace, machine: machine, now: now)
        card.options = options
        var timeline = timeline
        // The newest wait, while the workspace still waits, says why (the row's own reason).
        if let first = timeline.first, first.kind == .waiting, first.text == nil, case .waiting = workspace.activity {
            timeline[0].text = workspace.detail.needsInput
        }
        if !options.showsGit { card.facts.removeAll { $0.kind == "branch" || $0.kind == "pullRequest" } }
        if options.showsPorts, let ports = workspace.ports, !ports.isEmpty {
            let at = card.facts.firstIndex { $0.kind == "machine" || $0.kind == "status" || $0.kind == "more" || $0.kind == Fact.lastReplyKind }
            card.facts.insert(Fact(icon: .network, text: ports, kind: "ports"), at: at ?? card.facts.count)
        }
        if !options.showsTimings {
            card.activitySince = nil
            for index in card.facts.indices { card.facts[index].since = nil }
        }
        let shown = timeline.filter { entry in
            switch entry.kind {
            case .prompt, .started: options.showsPrompts
            case .waiting, .finished, .failed: options.showsWaiting
            }
        }
        switch options.layout {
        case .classic:
            break
        case .compact:
            card.timeline = Array(shown.prefix(options.historyRows))
        case .timeline:
            card.timeline = Array(shown.prefix(options.historyRows))
            if options.showsTimings { card.stats = stats(timeline, now: now) }
        case .log:
            // The history alone: only why the workspace waits stays above it.
            card.facts.removeAll { $0.kind != "needsInput" }
            card.timeline = Array(shown.prefix(options.historyRows))
            if options.showsTimings { card.stats = stats(timeline, now: now) }
        case .minimal:
            card.facts.removeAll { $0.kind != "needsInput" && $0.kind != "task" }
            if !card.facts.contains(where: { $0.kind == "task" }),
               let prompt = timeline.first(where: { $0.kind == .prompt && $0.text != nil })?.text {
                card.facts.append(Fact(icon: .composerSend, text: prompt, lines: 2, kind: "task"))
            }
        }
        return card
    }

    /// "Prompts: 4 · Worked 12m" over `timeline` (newest first): the time from each prompt or
    /// start to the next moment after it that is a wait, finish, failure or later prompt, a running
    /// turn until `now`. Nil with neither prompts nor worked time.
    static func stats(_ timeline: [SidebarTimelineEntry], now: Date) -> String? {
        let prompts = timeline.filter { $0.kind == .prompt }.count
        var worked: TimeInterval = 0
        var end: Date? = now
        for entry in timeline {
            switch entry.kind {
            case .waiting, .finished, .failed: end = entry.date
            case .prompt, .started:
                if let stop = end { worked += max(0, stop.timeIntervalSince(entry.date)) }
                // An older prompt with no end between worked until this one.
                end = entry.date
            }
        }
        guard prompts > 0 || worked > 0 else { return nil }
        return Strings.timelineStats(prompts: prompts, worked: worked >= 1 ? elapsed(since: now.addingTimeInterval(-worked), now: now) : nil)
    }

    private static let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMMd")
        return formatter
    }()

    /// A history line's time: the clock time today ("2:03 PM"), else the day ("Oct 18").
    static func timelineTime(_ date: Date, now: Date) -> String {
        Calendar.current.isDate(date, inSameDayAs: now) ? clockFormatter.string(from: date) : dayFormatter.string(from: date)
    }

    /// The facts card (the classic layout): one row per meaningful fact.
    private static func facts(_ workspace: SidebarWorkspace, machine: SidebarMachine?, now: Date) -> Self {
        let remote = machine.flatMap { $0.kind == .local ? nil : $0 }
        var facts: [Fact] = []
        let detail = workspace.detail
        if let reason = detail.needsInput { facts.append(Fact(icon: .statusNeedsinput, text: reason, lines: 3, kind: "needsInput")) }
        // The person's own notes and the lane they pinned (classic's description and status).
        if let notes = workspace.workspaceDescription?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty {
            facts.append(Fact(icon: .textDescription, text: notes, lines: 6, kind: "description"))
        }
        if let status = workspace.taskStatus {
            facts.append(Fact(icon: status.iconName, text: status.title, mark: status.symbol, kind: "taskStatus"))
        }
        // The unread notification's text, which a compact row no longer draws by default; without
        // one, how many items are unread (rows draw no count, `SidebarRowBadgeStyle`).
        if let text = workspace.notificationText, !text.isEmpty {
            facts.append(Fact(icon: .notification, text: text, lines: 2, kind: "notification"))
        } else if case let .count(n) = workspace.unread, n > 0 {
            facts.append(Fact(icon: .notification, text: Strings.unreadCount(n), kind: "unread"))
        }
        if let agent = workspace.agentName {
            facts.append(Fact(icon: .agentChat, text: [agent, detail.model].compactMap { $0 }.joined(separator: " · "), kind: "agent"))
        }
        if let task = detail.task { facts.append(Fact(icon: .textDescription, text: task, lines: 3, kind: "task")) }
        for presence in workspace.presence.prefix(2) {
            facts.append(Fact(icon: toolIcon(presence.activity), text: Strings.presenceLine(presence), kind: "presence"))
        }
        if let command = detail.command { facts.append(Fact(icon: .terminal, text: command, since: detail.commandSince, kind: "command")) }
        if let folder = workspace.directory.flatMap({ $0.isEmpty ? nil : folderName($0) }) { facts.append(Fact(icon: .folder, text: folder, kind: "folder")) }
        if let branch = workspace.branch, !branch.isEmpty { facts.append(Fact(icon: .gitBranch, text: branch, kind: "branch")) }
        if let pr = workspace.pullRequest, !pr.isEmpty { facts.append(Fact(icon: .gitPullrequest, text: pr, kind: "pullRequest")) }
        if let remote {
            // The machine and whether it is reachable, as a dot (Codex's sidebar card); a machine
            // that is not connected says how, in its color, under it.
            let own = ownIcon(remote.icon)
            let tone = connectionTone(remote.status)
            // The Chief's subagent workspaces say who started them here, not on their row.
            let name = remote.id.isLocalChief ? Strings.startedByChief : remote.name
            facts.append(Fact(icon: hostIcon(remote), text: name, mark: own.mark, image: own.image, kind: "machine",
                              accessory: .dot(tone)))
            if let word = connectionWord(remote.status) {
                facts.append(Fact(icon: .statusDisconnected, text: word, kind: "machineStatus", ink: tone))
            }
        }
        // As many entries as the row shows, then how many more (the daemon keeps up to 64).
        let entries = workspace.reported?.entries ?? []
        for entry in entries.prefix(SidebarWorkspaceStatus.visibleEntryLimit) {
            facts.append(Fact(icon: .listBulletItem, text: entry.displayText, mark: entry.icon, image: entry.image))
        }
        if entries.count > SidebarWorkspaceStatus.visibleEntryLimit {
            facts.append(Fact(icon: .overflowMore, text: Strings.statusMore(entries.count - SidebarWorkspaceStatus.visibleEntryLimit), kind: "more"))
        }
        // The checklist, each item with its state's mark, as many as the status block shows.
        for item in workspace.checklist.prefix(Self.visibleChecklistLimit) {
            facts.append(Fact(icon: .listBulletItem, text: item.text, mark: item.state.symbol, kind: "checklist"))
        }
        if workspace.checklist.count > Self.visibleChecklistLimit {
            facts.append(Fact(icon: .overflowMore, text: Strings.statusMore(workspace.checklist.count - Self.visibleChecklistLimit), kind: "more"))
        }
        // The agent chat's last reply, when no task says more: the card's last line, under the
        // metadata, two lines at most (Leo 2026-10-19, Claude desktop's session card).
        if detail.task == nil, let message = workspace.lastMessage, !message.isEmpty {
            facts.append(Fact(icon: .agentChatList, text: message, lines: 2, kind: Fact.lastReplyKind))
        }
        return WorkspaceHoverCardContent(
            title: workspace.title, icon: remote.map(hostIcon) ?? workspace.kind.iconName,
            age: workspace.lastActivity.flatMap { age(since: $0, now: now) }, facts: facts,
            activity: workspace.activity, activityStyle: workspace.activityStyle, activitySince: detail.activitySince)
    }

    /// The card's fields for the user's card (`ctx.card`).
    var cardFacts: SidebarCardFacts {
        SidebarCardFacts(
            title: title, status: Strings.activity(activity), statusSinceMs: activitySince.map { $0.timeIntervalSince1970 * 1000 },
            age: age, facts: facts.map { .init(kind: $0.kind, text: $0.text, sinceMs: $0.since.map { $0.timeIntervalSince1970 * 1000 }) })
    }

    /// The icon of what an agent is doing (`SidebarPresence.Activity`).
    private static func toolIcon(_ activity: SidebarPresence.Activity) -> IconName {
        switch activity {
        case .editing: .toolEdit
        case .reading: .toolRead
        case .running: .toolShell
        case .browsing: .toolWeb
        case .thinking, .computerUse, .waiting: .agentActivity
        }
    }

    private static let elapsedFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        formatter.allowedUnits = [.day, .hour, .minute, .second]
        formatter.zeroFormattingBehavior = .dropAll
        return formatter
    }()

    /// How long since `date`, live on the card: "12s", "4m 12s", "1h 3m"; at least one second,
    /// also for a start ahead of this clock (another machine's daemon).
    static func elapsed(since date: Date, now: Date) -> String {
        elapsedFormatter.string(from: max(1, now.timeIntervalSince(date).rounded(.down))) ?? ""
    }

    /// `text · 4m 12s` for a running fact, else `text`.
    static func withElapsed(_ text: String, since: Date?, now: Date) -> String {
        guard let since else { return text }
        return text + " · " + elapsed(since: since, now: now)
    }

    /// The one resource line, or nil while the workspace is quiet.
    static func resourceLine(_ report: ResourceReport?) -> String? {
        guard let total = report?.total,
              (total.cpu ?? 0) >= notableCPU || total.memoryBytes >= notableMemoryBytes else { return nil }
        return ResourceFormat.line(total)
    }

    /// The resource row: CPU and memory with the last seconds of CPU as bars, warm when hot
    /// (Leo 2026-10-19: "the CPU related stuff, I think people want to know"); nil while the
    /// workspace is quiet. `history` is the CPU of each sample since the card showed, newest last.
    static func resourceRow(_ report: ResourceReport?, history: [Double]) -> HoverCardRowContent? {
        guard let line = resourceLine(report), let total = report?.total else { return nil }
        let cpu = total.cpu ?? 0
        let tone: HoverCardTone = cpu >= 2 ? .danger : cpu >= 1 ? .attention : .secondary
        // Each bar against the busiest sample, at least one core, so a quiet second reads low.
        let peak = max(1, history.max() ?? 0)
        let bars = history.isEmpty ? nil : HoverCardAccessory.bars(history.map { $0 / peak }, tone: tone)
        return HoverCardRowContent(text: line, ink: tone == .secondary ? .secondary : tone, accessory: bars)
    }

    /// A machine's link as a color: green connected, yellow on its way, red when it cannot connect.
    static func connectionTone(_ status: SidebarMachine.Status) -> HoverCardTone {
        switch status {
        case .connected, .updateAvailable: .success
        case .connecting, .reconnecting, .installing, .updateRequired, .installRequired: .attention
        case .offline, .authFailed, .unreachable, .failed: .danger
        }
    }

    /// What a machine that is not plainly connected is doing, nil when connected.
    static func connectionWord(_ status: SidebarMachine.Status) -> String? {
        switch status {
        case .connected, .updateAvailable: nil
        case .offline: Strings.statusOffline
        case .connecting: Strings.statusConnecting
        case .installing: Strings.statusInstalling
        default: Strings.attentionStatus(status)
        }
    }

    /// The folder's own name: "~/Projects/site" reads "site", and the home
    /// folder reads as its name, not "~".
    static func folderName(_ directory: String) -> String {
        let path = (directory as NSString).expandingTildeInPath
        let name = (path as NSString).lastPathComponent
        return name.isEmpty ? directory : name
    }

    /// A machine's own icon (`SidebarMachine.icon`) as a fact's mark (an emoji or SF Symbol
    /// name) or image (a stored asset); neither without one, so the kind's symbol draws.
    private static func ownIcon(_ icon: WorkspaceIcon?) -> (mark: String?, image: SidebarFavicon?) {
        switch icon {
        case .symbol(let name, _)?: (name, nil)
        case .emoji(let text, _)?: (text, nil)
        case .favicon(let image)?: (nil, image)
        case .swatch?, nil: (nil, nil)
        }
    }

    private static func hostIcon(_ machine: SidebarMachine) -> IconName {
        switch machine.kind {
        case .local: .machineLocal
        case .cloud: .cloud
        case .ssh, .server: .machineRemote
        }
    }

    private static let ageFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 1
        formatter.allowedUnits = [.weekOfMonth, .day, .hour, .minute]
        return formatter
    }()

    /// "4w", "3d", "5h", "12m"; nil under a minute.
    static func age(since date: Date, now: Date) -> String? {
        let seconds = now.timeIntervalSince(date)
        guard seconds >= 60 else { return nil }
        return ageFormatter.string(from: seconds)
    }
}
