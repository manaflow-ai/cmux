import CmuxNextDesign
import CmuxNextIcons
import CmuxNextResources
import Foundation

/// What the workspace hover card says (Leo 2026-10-08, Codex parity): a
/// title row (the name, a kind or host icon, the relative age) and one row
/// per meaningful fact, each with an icon: the repository and branch (or the folder), pull
/// request, computer, the agent working there (cx-13w3), and each reported status entry with its
/// own icon (cx-qno.11.1), then the preview line (`Preview`). CPU and memory show as one line,
/// and only when notable.
///
/// Leo 2026-10-21 ("this doesn't line up nor work very well"): a home folder is no fact (its
/// "leoli" line was noise), and the preview line says where the workspace stands (it needs you,
/// or its pull request's state in the icon's color) before it falls back to the raw last reply.
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
        /// The icon's own ink (a pull request's state, a wait); nil is the metadata ink.
        var iconTone: HoverCardTone?
        /// The card's preview line (`Preview`): the last row, a step apart from the metadata.
        var isPreview = false
        /// The machine a machine row names: its icon draws that machine's color pick, if any.
        var machine: String?

        /// The row the shared hover card row draws (`HoverCardRowView`).
        var row: HoverCardRowContent {
            HoverCardRowContent(text: text, ink: ink ?? (isMessage ? .primary : .secondary), lines: lines, status: status,
                                statusTone: statusTone, additions: additions, deletions: deletions, accessory: accessory,
                                iconTone: iconTone, iconMachine: machine)
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
    /// Cloud/remote identity stays visible above the optional details; local has none.
    var host: Fact? = nil
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
    static func make(_ workspace: SidebarWorkspace, machine: SidebarMachine?, now: Date,
                     pullRequests: SidebarPullRequestBadge? = nil, home: String = NSHomeDirectory()) -> Self {
        make(workspace, machine: machine, now: now, options: { var o = WorkspaceHoverCardOptions(); o.layout = .classic; return o }(),
             timeline: [], pullRequests: pullRequests, home: home)
    }

    /// The card for `workspace` as `options` lay it out (u3320), with its `timeline` (newest first).
    /// `looked`: when the person last looked at it (`sidebar.sinceLooked`), for the line that says
    /// what its agents did since. `pullRequests`: the row's pull request badge
    /// (`SidebarSessionTree.pullRequests`), for the repository and the state; `home`: this Mac's
    /// home folder, which is no fact.
    static func make(_ workspace: SidebarWorkspace, machine: SidebarMachine?, now: Date,
                     options: WorkspaceHoverCardOptions, timeline: [SidebarTimelineEntry], looked: Date? = nil,
                     pullRequests: SidebarPullRequestBadge? = nil, home: String = NSHomeDirectory()) -> Self {
        var card = facts(workspace, machine: machine, now: now, pullRequests: pullRequests, home: home, showsGit: options.showsGit)
        // Keep the hover card in step with the row: a local host plus the same
        // session title is metadata without information and gets no fact row.
        card.facts.removeAll { fact in
            WorkspaceRowContent.nonRedundantDetail(fact.text, title: workspace.title) == nil
        }
        if let looked, let text = sinceLooked(timeline, after: looked) {
            card.facts.insert(Fact(icon: .historyRecent, text: text, kind: sinceLookedKind), at: 0)
        }
        card.options = options
        var timeline = timeline
        // The newest wait, while the workspace still waits, says why (the row's own reason).
        if let first = timeline.first, first.kind == .waiting, first.text == nil, case .waiting = workspace.activity {
            timeline[0].text = needsInputReason(workspace)
        }
        if !options.showsGit { card.facts.removeAll { $0.kind == "branch" || $0.kind == "pullRequest" } }
        if options.showsPorts, let ports = workspace.ports, !ports.isEmpty {
            let at = card.facts.firstIndex { $0.kind == "machine" || $0.kind == "status" || $0.kind == "more" || $0.isPreview }
            card.facts.insert(Fact(icon: .network, text: ports, kind: "ports"), at: at ?? card.facts.count)
        }
        if !options.showsTimings {
            card.activitySince = nil
            for index in card.facts.indices { card.facts[index].since = nil }
        }
        // The History lists what was asked and what happened, never acpmux's inbox notices
        // ("[inbox] New messages from other agents…"); the stats still count their work.
        let shown = timeline.filter { entry in
            if entry.isNotice { return false }
            return switch entry.kind {
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
            // The history alone: only why the workspace waits (its reason, else "Needs you") stays above it.
            card.facts.removeAll { $0.kind != "needsInput" && $0.kind != needsYouKind && $0.kind != sinceLookedKind }
            card.timeline = Array(shown.prefix(options.historyRows))
            if options.showsTimings { card.stats = stats(timeline, now: now) }
        case .minimal:
            card.facts.removeAll { $0.kind != "needsInput" && $0.kind != needsYouKind && $0.kind != "task" && $0.kind != sinceLookedKind }
            if !card.facts.contains(where: { $0.kind == "task" }),
               let prompt = timeline.first(where: { $0.kind == .prompt && $0.text != nil })?.text {
                // Above the "Needs you" line, which stays the card's last.
                let at = card.facts.firstIndex { $0.kind == needsYouKind } ?? card.facts.count
                card.facts.insert(Fact(icon: .composerSend, text: prompt, lines: 2, kind: "task"), at: at)
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

    /// The facts card (the classic layout): one row per meaningful fact. Without `showsGit` the
    /// place reads as the folder alone (no branch, no repository from a pull request).
    private static func facts(_ workspace: SidebarWorkspace, machine: SidebarMachine?, now: Date,
                              pullRequests: SidebarPullRequestBadge?, home: String, showsGit: Bool) -> Self {
        let remote = machine.flatMap { $0.kind == .local ? nil : $0 }
        var facts: [Fact] = []
        let detail = workspace.detail
        let previewLine = Self.preview(workspace, pullRequests: pullRequests, showsGit: showsGit)
        if let reason = needsInputReason(workspace) {
            facts.append(Fact(icon: .statusNeedsinput, text: reason, lines: 3, kind: "needsInput", iconTone: .attention))
        }
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
        // What its agents run below their turns now: how many subagents and commands, and which
        // (Leo 2026-11-01: "being able to see the # of associated subagents and whatnot").
        facts += WorkspaceHoverCardWork.facts(detail)
        for presence in workspace.presence.prefix(2) {
            facts.append(Fact(icon: toolIcon(presence.activity), text: Strings.presenceLine(presence), kind: "presence"))
        }
        if let command = detail.command { facts.append(Fact(icon: .terminal, text: command, since: detail.commandSince, kind: "command")) }
        if let place = Self.place(workspace, pullRequests: showsGit ? pullRequests : nil, home: home, showsGit: showsGit) { facts.append(place) }
        let pullRequest = pullRequestFact(workspace, pullRequests: pullRequests)
        if previewLine != .pullRequest, let pullRequest { facts.append(pullRequest) }
        if let remote {
            // The machine and whether it is reachable, as a dot (Codex's sidebar card); a machine
            // that is not connected says how, in its color, under it.
            let tone = connectionTone(remote.status)
            facts.append(Fact(icon: hostIcon(remote), text: remote.kind == .cloud ? Strings.hoverCloud : remote.name,
                              mark: remote.kind == .cloud ? nil : "globe", kind: "machine",
                              accessory: .dot(tone), machine: remote.name))
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
        // The preview, the card's last line under the metadata: the pull request's state when the
        // workspace has one, else the agent chat's last reply (two lines at most, Leo 2026-10-19,
        // Claude desktop's session card). A wait says why in the first row, so no reply shows.
        switch previewLine {
        case .pullRequest:
            if var pullRequest { pullRequest.isPreview = true; facts.append(pullRequest) }
        case .message(let message):
            facts.append(Fact(icon: .agentChatList, text: message, lines: 2, kind: Fact.lastReplyKind, isPreview: true))
        case .needsYou:
            // The reason row or the waiting status row says it already, so no reply shows under
            // it. With neither (a chip that needs the person), the preview says "Needs you".
            guard needsInputReason(workspace) == nil, !workspace.activity.waitsForPerson else { break }
            facts.append(Fact(icon: .statusNeedsinput, text: Strings.priorityNeedsYou, kind: needsYouKind, ink: .attention,
                              iconTone: .attention, isPreview: true))
        case .empty:
            break
        }
        return WorkspaceHoverCardContent(
            title: workspace.title, icon: remote.map(hostIcon) ?? workspace.kind.iconName,
            age: workspace.lastActivity.flatMap { age(since: $0, now: now) }, facts: facts, host: facts.first { $0.kind == "machine" },
            activity: workspace.activity, activityStyle: workspace.activityStyle, activitySince: detail.activitySince)
    }

    /// What the card's last line says (Leo 2026-10-21): the latest meaningful status, and the
    /// agent chat's raw last reply only when there is none.
    enum Preview: Equatable {
        /// The workspace waits on the person: the reason row or the waiting status row says so,
        /// else a "Needs you" line; never the raw last reply.
        case needsYou
        /// Its pull request, in its state's color.
        case pullRequest
        /// No status: the agent chat's last reply, when no task says more.
        case message(String)
        /// Nothing to preview.
        case empty
    }

    /// The fact kind of the preview's "Needs you" line.
    static let needsYouKind = "needsYou"

    /// The preview for `workspace`: a wait first, then a pull request (unless `showsGit` is off),
    /// then the last reply. Pure.
    static func preview(_ workspace: SidebarWorkspace, pullRequests: SidebarPullRequestBadge?, showsGit: Bool = true) -> Preview {
        if needsInputReason(workspace) != nil || workspace.agentChip == .needsYou { return .needsYou }
        if workspace.activity.waitsForPerson { return .needsYou }
        if showsGit, newestPullRequest(pullRequests) != nil || workspace.pullRequest?.isEmpty == false { return .pullRequest }
        if let message = lastReply(workspace) { return .message(message) }
        return .empty
    }

    /// Why the workspace waits on the person, trimmed; a blank reason is none.
    static func needsInputReason(_ workspace: SidebarWorkspace) -> String? {
        guard let reason = workspace.detail.needsInput?.trimmingCharacters(in: .whitespacesAndNewlines), !reason.isEmpty
        else { return nil }
        return reason
    }

    /// The agent chat's last reply worth a line: none while a task says more.
    private static func lastReply(_ workspace: SidebarWorkspace) -> String? {
        guard workspace.detail.task == nil, let message = workspace.lastMessage?.trimmingCharacters(in: .whitespacesAndNewlines),
              !message.isEmpty else { return nil }
        return message
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

    /// A machine's link as a color: green connected, yellow on its way, red when it cannot connect,
    /// grey when paused (it resumes on attach).
    static func connectionTone(_ status: SidebarMachine.Status) -> HoverCardTone {
        switch status {
        case .connected, .updateAvailable: .success
        case .connecting, .reconnecting, .installing, .updateRequired, .installRequired, .pausing, .resuming, .deleting, .disconnected: .attention
        case .offline, .authFailed, .unreachable, .failed: .danger
        case .paused, .pausedIdle: .secondary
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

    /// The folder worth a line: its own name, or nil for none, `~`, `home` (this Mac's home
    /// folder), a remote machine's home (`/home/<user>`, `/Users/<user>`, `/root`) or `/`. A
    /// workspace that never left home says nothing by naming the user (Leo 2026-10-21). Any
    /// `/Users/<name>` counts, `/Users/Shared` too: a folder one level under `/Users` is a home.
    static func meaningfulFolder(_ directory: String?, home: String = NSHomeDirectory()) -> String? {
        guard var path = directory?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else { return nil }
        if path == "~" || path.hasPrefix("~/") { path = (home as NSString).appendingPathComponent(String(path.dropFirst())) }
        let parts = (path as NSString).standardizingPath.split(separator: "/", omittingEmptySubsequences: true)
        let homeParts = (home as NSString).standardizingPath.split(separator: "/", omittingEmptySubsequences: true)
        if parts.isEmpty || parts == homeParts || parts == ["root"] { return nil }
        if parts.count == 2, parts[0] == "home" || parts[0] == "Users" { return nil }
        return String(parts[parts.count - 1])
    }

    /// The repository's name ("cmux"): the newest pull request's (`owner/repo`), else the folder's
    /// when the workspace is on a branch (a checkout's folder is its repository); nil when neither
    /// says.
    /// A worktree's folder that spells its whole branch ("lane--fix-card" on `lane/fix-card`) says
    /// the branch twice, so it names nothing. A folder that only matches the branch's last part
    /// ("card" on `feature/card`) is a repository like any other.
    static func repositoryName(pullRequests: SidebarPullRequestBadge?, folder: String?, branch: String?) -> String? {
        if let repository = newestPullRequest(pullRequests)?.repository, let name = repository.split(separator: "/").last, !name.isEmpty {
            return String(name)
        }
        guard let branch, !branch.isEmpty, let folder else { return nil }
        func letters(_ text: some StringProtocol) -> String { String(text.lowercased().filter { $0.isLetter || $0.isNumber }) }
        return letters(folder) == letters(branch) ? nil : folder
    }

    /// Where the workspace works, as one line: "cmux · feat-cmux-next" on a branch, the folder
    /// alone off one, nil in the home folder with no branch. Without `showsGit`, the folder only.
    static func place(_ workspace: SidebarWorkspace, pullRequests: SidebarPullRequestBadge?, home: String,
                      showsGit: Bool = true) -> Fact? {
        let folder = meaningfulFolder(workspace.directory, home: home)
        if showsGit, let branch = workspace.branch, !branch.isEmpty {
            let repository = repositoryName(pullRequests: pullRequests, folder: folder, branch: branch)
            let text = [repository, branch].compactMap { $0 }.joined(separator: WorkspaceRowContent.separator)
            return Fact(icon: .gitBranch, text: text, kind: "branch")
        }
        return folder.map { Fact(icon: .folder, text: $0, kind: "folder") }
    }

    /// The pull request the card names: the newest open or merged one, else the newest.
    static func newestPullRequest(_ badge: SidebarPullRequestBadge?) -> SidebarPullRequestItem? {
        guard let items = badge?.items else { return nil }
        return items.first { $0.state != .closed } ?? items.first
    }

    /// The pull request row: the newest one's state word and number in its color, its icon in
    /// that color, its size; else the hook's `pr` status entry as reported. Nil without either.
    static func pullRequestFact(_ workspace: SidebarWorkspace, pullRequests: SidebarPullRequestBadge?) -> Fact? {
        if let item = newestPullRequest(pullRequests) {
            let tone = pullRequestTone(item.state)
            let text = item.title.isEmpty ? "#\(item.number)" : "#\(item.number) \(item.title)"
            return Fact(icon: .gitPullrequest, text: text, kind: "pullRequest", status: Strings.pullRequestState(item.state),
                        statusTone: tone, additions: item.additions > 0 ? item.additions : nil,
                        deletions: item.deletions > 0 ? item.deletions : nil, iconTone: tone)
        }
        guard let pr = workspace.pullRequest, !pr.isEmpty else { return nil }
        return Fact(icon: .gitPullrequest, text: pr, kind: "pullRequest")
    }

    /// A pull request state's color, as the row's badge and the pull request card color it.
    static func pullRequestTone(_ state: SidebarPullRequestItem.State) -> HoverCardTone {
        switch state {
        case .passing: .success
        case .merged: .merged
        case .failing: .danger
        case .conflict, .draft: .attention
        case .closed: .tertiary
        }
    }

    /// The title's existing kind glyph; the remote identity row uses a globe.
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

private extension StatusIndicatorState {
    /// Waiting for the person (its status row says so).
    var waitsForPerson: Bool {
        if case .waiting = self { return true }
        return false
    }
}
