public import CmuxNextDesign
public import Foundation

/// What one workspace row draws (SIDEBAR-ROWS-MINIMAL-AND-CUSTOMIZABLE): the
/// one place that turns a workspace's facts and `sidebar.workspaceRow.*`
/// into row content. The layout sizes the row from it and the row view draws
/// only what it says, so no other code adds a line, a count or a badge.
///
/// The working-indicator slot: `showsWorking` is true while some tab has
/// agent work (an acpmux turn, a hook or OSC 7501 `working`:
/// `SidebarWorkspace.agentWorking`) and the `working` element is on. The
/// status glyph then draws the working dots (`StatusIndicatorState.working`);
/// a stronger state of the workspace (waiting, error) takes the one slot.
public nonisolated struct WorkspaceRowContent: Hashable, Sendable {
    /// Draw the user's icon (nil when the user set none or turned icons off).
    public var icon: WorkspaceIcon?
    /// The workspace's color as the row's leading rail or full fill (`workspaceColors.indicatorStyle`,
    /// #25653); nil for the dot style, an uncolored workspace or `sidebar.showColors` off.
    public var rowColor: GroupColor?
    /// How `rowColor` draws: `.leftRail` or `.fill` (`.dot` draws it as the icon instead).
    public var colorStyle: WorkspaceColorIndicatorStyle = .dot
    /// The second line: the shown second-line elements in order, joined.
    public var detail: String?
    /// The tab count, when that element is on.
    public var tabCount: Int?
    /// The pull request / CI badge text, when that element is on.
    public var badge: String?
    /// The status glyph: attention states (waiting, error, success) always;
    /// busy or paused only for an agent turn with `working` on, or with
    /// `progress` on.
    public var activity: StatusIndicatorState
    /// The bar under the row, when `progress` is on: a measured fraction or
    /// an error only. An indeterminate report draws no bar; the status glyph
    /// already says the workspace works (Lawrence 2026-10-13 and 2026-10-18:
    /// the full-width line under every busy row read as a stray underline).
    public var progress: SidebarProgress?
    /// The agent-working indicator slot (WORKING-AND-LOADING-INDICATORS).
    public var showsWorking: Bool
    /// The row badge draws each state apart (`sidebar.detailedStatusIcons`): working, waiting,
    /// error, done. Off (the default), it draws Working or Ready only (`WorkspaceRowBadges`).
    public var detailedStatus = false
    /// An expanded row (`sidebar.density`): its trailing marks sit on the title's line.
    public var expanded = false
    /// Expanded rows: the time since the last change, on the title's line.
    public var time: String?
    /// Expanded rows: a third line (the computer, the pull request).
    public var meta: String?
    /// A one-line status on an otherwise one-line compact row (one reported entry, or the hooks'
    /// status line), drawn dim on the right of the name's line so the row keeps its height
    /// (Thunderdome 2026-10-14). The hover card lists every entry.
    public var trailingStatus: String?
    /// What the name's line ends with: an expanded row's age, else a one-line status.
    public var trailingText: String? { time ?? trailingStatus }
    /// Compact rows under a badge style (`SidebarRowBadgeStyle`): the dim time since the last
    /// change on the right, unless the second line shows the last activity already.
    public var badgeTime: String?
    /// The status block under the name (classic's): the reported entries
    /// with `agentStatus` on, the log line with `log` on and the progress
    /// label with `progress` on. Nil when none of those is reported, so a
    /// quiet workspace keeps its one-line row.
    public var status: SidebarWorkspaceStatus?
    /// The computer the workspace runs on, while the sidebar lists more than one (SidebarMachineMark).
    public var machine: SidebarMachineMark?
    /// The session tree (`sidebar.sessionTree`): 1 under the workspace whose agent started this one's.
    public var treeDepth = 0
    /// The session tree: the Command-number that goes to the row (1 to 9), drawn as a keycap.
    public var keycap: Int?
    /// The session tree: the row's pull requests, a glyph and a count in their status color.
    public var pullRequests: SidebarPullRequestBadge?
    /// The session tree: a parent's chevron (nil without children).
    public var treeFold: SidebarTreeFold?
    /// The session tree: a folded parent's descendants by state, drawn as chips.
    public var rollUp: SidebarTreeRollUp?
    /// The Priority view's chip (`SidebarWorkspace.agentChip`) when it asks for something
    /// (`rowChip`), for the row's accessibility label. Never drawn: a row shows no status words
    /// (Leo 2026-10-21); needs you is the badge's yellow dot.
    public var chip: SidebarPriorityEntry.State?
    /// What the working agent does now (`SidebarWorkspace.agentStep`), in place of the second
    /// line's text: the row view draws it as "Now: …". Set only on a row that has a second line.
    public var now: String?

    public init(icon: WorkspaceIcon? = nil, detail: String? = nil, tabCount: Int? = nil, badge: String? = nil,
                activity: StatusIndicatorState = .idle, progress: SidebarProgress? = nil, showsWorking: Bool = false,
                status: SidebarWorkspaceStatus? = nil) {
        self.icon = icon
        self.detail = detail
        self.tabCount = tabCount
        self.badge = badge
        self.activity = activity
        self.progress = progress
        self.showsWorking = showsWorking
        self.status = status
    }

    /// Separates second-line items.
    public static let separator = " · "

    /// The content of `ws`'s row under `preferences`; `now` decides whether
    /// the last activity shows a time (today) or a date. `machine` (the
    /// computer of a workspace in the one-list sidebar that is not this Mac)
    /// leads the second line whatever the preferences show, followed by the
    /// workspace's folder on that computer and a starting Cloud machine's
    /// stage (`SidebarWorkspace.stage`).
    init(_ ws: SidebarWorkspace, preferences: WorkspaceRowPreferences, now: Date = Date(), machine: String? = nil, ages: AgeTextCache) {
        self.init(ws, preferences: preferences, now: now, machine: machine, ageCache: ages)
    }

    public init(_ ws: SidebarWorkspace, preferences: WorkspaceRowPreferences, now: Date = Date(), machine: String? = nil) {
        self.init(ws, preferences: preferences, now: now, machine: machine, ageCache: AgeTextCache())
    }

    private init(_ ws: SidebarWorkspace, preferences: WorkspaceRowPreferences, now: Date, machine: String?, ageCache ages: AgeTextCache) {
        let set = preferences.resolved(for: ws.rowKind)
        // Another computer's workspace names its folder after the computer, so the row says
        // where its terminals run (`host · ~/code/app`), unless the folder element shows it already (cx-gaq9).
        let folder = machine != nil && !set.secondLine.contains(.directory) ? Self.nonEmpty(ws.directory) : nil
        let lead = [Self.nonEmpty(machine), folder, Self.nonEmpty(ws.stage), Self.descriptionLine(ws)].compactMap { $0 }
        let secondLine = set.secondLine.compactMap { element in Self.text(of: element, in: ws, now: now).map { (element, $0) } }
        var items = lead + secondLine.map(\.1)
        var status = Self.status(ws.reported, set)
        // A one-line status leaves a one-line row one line: its text moves to the name's line.
        let others = lead + secondLine.filter { $0.0 != .agentStatus }.map(\.1)
        var trailing: String?
        if others.isEmpty {
            if let line = secondLine.first(where: { $0.0 == .agentStatus })?.1, status == nil {
                (trailing, items) = (line, [])
            } else if let block = status, block.entries.count == 1, block.log == nil, block.progressLabel == nil {
                (trailing, status) = (block.entries[0].displayText, nil)
            }
        }
        let working = ws.agentWorking && set.shows(.working)
        self.init(
            // Task status is already represented by the trailing status dots; only a user icon
            // belongs before the title (Chrome's chat list has no extra idle/status ring).
            icon: set.shows(.icon) ? ws.icon : nil,
            detail: items.isEmpty ? nil : items.joined(separator: Self.separator),
            tabCount: set.shows(.tabCount) ? ws.tabs.count : nil,
            badge: set.shows(.pullRequest) ? Self.nonEmpty(ws.pullRequest) : nil,
            activity: Self.activity(ws.activity, working: working, progress: set.shows(.progress)),
            progress: set.shows(.progress) ? Self.bar(ws) : nil,
            showsWorking: working,
            status: status
        )
        trailingStatus = trailing
        badgeTime = set.secondLine.contains(.lastActivity) ? nil : ws.lastActivity.map { Self.ageText($0, now: now, ages: ages) }
    }

    /// An expanded row (`sidebar.density`, cx-13w3; T3 Code / Codex
    /// style): the user's icon only (no kind glyph, WORKSPACE-ROWS-NO-DEFAULT-ICON), a dim second line
    /// (an unread notification's text when `sidebar.workspaceRow.notification` shows it, else the agent chat's last message, else the agent's status line, else
    /// the folder and branch), the time
    /// since the last change on the title's line, and a third line for the
    /// computer and the pull request. `now` is the start of today, so the
    /// time reads in days; a change today shows its time.
    public init(expanded ws: SidebarWorkspace, now: Date, machine: String? = nil, showsNotification: Bool = true,
                showsPullRequest: Bool = true) {
        self.init(expanded: ws, now: now, machine: machine, showsNotification: showsNotification,
                  showsPullRequest: showsPullRequest, ages: AgeTextCache())
    }

    init(expanded ws: SidebarWorkspace, now: Date, machine: String?, showsNotification: Bool, showsPullRequest: Bool,
         ages: AgeTextCache) {
        let place = [Self.nonEmpty(ws.directory), Self.nonEmpty(ws.branch)].compactMap { $0 }
        let meta = [Self.nonEmpty(machine), Self.nonEmpty(ws.stage), showsPullRequest ? Self.nonEmpty(ws.pullRequest) : nil].compactMap { $0 }
        self.init(
            icon: ws.icon,
            detail: (showsNotification ? Self.nonEmpty(ws.notificationText) : nil) ?? Self.descriptionLine(ws)
                ?? Self.nonEmpty(ws.lastMessage) ?? Self.nonEmpty(ws.status)
                ?? (place.isEmpty ? nil : place.joined(separator: Self.separator)),
            activity: Self.activity(ws.activity, working: ws.agentWorking, progress: true),
            progress: Self.bar(ws),
            showsWorking: ws.agentWorking
        )
        expanded = true
        time = ws.lastActivity.map { Self.ageText($0, now: now, ages: ages) }
        self.meta = meta.isEmpty ? nil : meta.joined(separator: Self.separator)
    }

    /// The age of a change, short: a time today, else days (`3d`), weeks
    /// (`3w`) or months (`5mo`), as T3 Code and Codex label chats.
    static func ageText(_ date: Date, now: Date, calendar: Calendar = .current, ages: AgeTextCache = AgeTextCache()) -> String {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        let minute = Int(date.timeIntervalSince1970 / 60)
        return ages.label(days: days <= 0 ? nil : days, minute: minute, locale: .current, timeZone: calendar.timeZone) {
            if days <= 0 { return date.formatted(date: .omitted, time: .shortened) }
            // One unit, from whole days, like All chats' ages (`SidebarChatsDesign.age`): no timer.
            let formatter = DateComponentsFormatter()
            formatter.unitsStyle = .abbreviated
            formatter.maximumUnitCount = 1
            formatter.allowedUnits = [.day, .weekOfMonth, .month]
            return formatter.string(from: TimeInterval(days) * 86_400) ?? ""
        }
    }

    /// The chip a row may draw: what asks for the user (needs you, failed, lost, Red CI). A finished
    /// chat says nothing in words (Leo 2026-10-21, "WHO BROUGHT BACK THE DONE AND THE TIMERS"): its
    /// unread dot is the cue. Working and idle never reach a row (`SidebarLaneStatus.chip`).
    static func rowChip(_ state: SidebarPriorityEntry.State?) -> SidebarPriorityEntry.State? {
        switch state {
        case .needsYou?, .failed?, .lost?, .ciFailing?: state
        case .done?, .working?, .idle?, nil: nil
        }
    }

    /// The part of `reported` the shown elements draw; nil when empty.
    static func status(_ reported: SidebarWorkspaceStatus?, _ set: WorkspaceRowElements) -> SidebarWorkspaceStatus? {
        guard let reported else { return nil }
        let block = SidebarWorkspaceStatus(entries: set.shows(.agentStatus) ? reported.entries : [],
                                           log: set.shows(.log) ? reported.log : nil,
                                           progressLabel: set.shows(.progress) ? reported.progressLabel : nil)
        return block.isEmpty ? nil : block
    }

    static func activity(_ state: StatusIndicatorState, working: Bool, progress: Bool) -> StatusIndicatorState {
        switch state {
        case .idle, .waiting, .error, .success: state
        case .busy, .paused: working || progress ? state : .idle
        // Agent work (WORKING-AND-LOADING-INDICATORS) shows only with `working` on.
        case .working: working ? state : .idle
        }
    }

    static func text(of element: WorkspaceRowElement, in ws: SidebarWorkspace, now: Date) -> String? {
        switch element {
        case .directory: nonEmpty(ws.directory)
        case .branch: nonEmpty(ws.branch)
        case .process: nonEmpty(ws.process)
        // The status block draws the reported entries; the line repeats none.
        case .agentStatus: ws.reported?.entries.isEmpty == false ? nil : nonEmpty(ws.status)
        case .ports: nonEmpty(ws.ports)
        case .lastActivity: ws.lastActivity.map { activityText($0, now: now) }
        case .notification: nonEmpty(ws.notificationText)
        case .icon, .tabCount, .pullRequest, .progress, .working, .log: nil
        }
    }

    /// A time today, else a short date: a fixed label needs no timer.
    static func activityText(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        calendar.isDate(date, inSameDayAs: now)
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(.dateTime.month(.abbreviated).day())
    }

    /// The progress a row draws as a bar: a value or an error. A connecting
    /// placeholder keeps its dimmed indeterminate bar (its only sign of life).
    static func bar(_ ws: SidebarWorkspace) -> SidebarProgress? {
        guard let progress = ws.progress else { return nil }
        return progress.value != nil || progress.isError || ws.rowState == .placeholder ? progress : nil
    }

    /// The description's first non-empty line, trimmed: what a row shows of it.
    static func descriptionLine(_ ws: SidebarWorkspace) -> String? {
        ws.workspaceDescription?.split(whereSeparator: \.isNewline).lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
    }

    static func nonEmpty(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        return text
    }
}
