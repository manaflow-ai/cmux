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

        /// What someone said or asked (a waiting reason, a notification, the task, the last
        /// reply): it reads in the primary ink. Every other row is metadata in the secondary ink,
        /// under the title (Claude desktop's session card: a title, muted metadata, the message).
        var isMessage: Bool { Self.messageKinds.contains(kind) }
        static let messageKinds: Set<String> = ["needsInput", "notification", "task", lastReplyKind]
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

    /// CPU of at least half a core, or memory of at least 1 GB, is worth a line.
    static let notableCPU = 0.5
    static let notableMemoryBytes: UInt64 = 1 << 30

    static func make(_ workspace: SidebarWorkspace, machine: SidebarMachine?, now: Date) -> Self {
        let remote = machine.flatMap { $0.kind == .local ? nil : $0 }
        var facts: [Fact] = []
        let detail = workspace.detail
        if let reason = detail.needsInput { facts.append(Fact(icon: .statusNeedsinput, text: reason, lines: 3, kind: "needsInput")) }
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
            let own = ownIcon(remote.icon)
            facts.append(Fact(icon: hostIcon(remote), text: remote.name, mark: own.mark, image: own.image, kind: "machine"))
        }
        // As many entries as the row shows, then how many more (the daemon keeps up to 64).
        let entries = workspace.reported?.entries ?? []
        for entry in entries.prefix(SidebarWorkspaceStatus.visibleEntryLimit) {
            facts.append(Fact(icon: .listBulletItem, text: entry.displayText, mark: entry.icon, image: entry.image))
        }
        if entries.count > SidebarWorkspaceStatus.visibleEntryLimit {
            facts.append(Fact(icon: .overflowMore, text: Strings.statusMore(entries.count - SidebarWorkspaceStatus.visibleEntryLimit), kind: "more"))
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
