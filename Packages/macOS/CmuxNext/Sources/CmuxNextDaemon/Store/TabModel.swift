import CmuxNextWakeups
public import Foundation
public import Observation

// Main-actor mirror records. Each record is a small @Observable final class
// with stable identity (durable ids), patched in place: a field is assigned
// only when its value changed, so Observation invalidates exactly the views
// that read it. A resync after a reconnect or daemon restart updates the same
// objects; numeric handles are refreshed on every snapshot.
//
// Focus, hover, drag, and scroll are not here: the daemon's `active*` fields
// are shared compatibility defaults, and user focus is client-local.

@Observable @MainActor
public final class TabModel: Identifiable {
    public let id: String
    public internal(set) var surface: SurfaceID
    public internal(set) var terminalID: TerminalID?
    public internal(set) var terminalIncarnation: TerminalIncarnation?
    /// Public terminal id (`term_…`) used by `attach-identity-v1`.
    public internal(set) var terminalResourceID: ResourceID?
    public internal(set) var kind: TabKind { didSet { refreshUnread() } }
    public internal(set) var name: String?
    /// The title as the program or page set it, raw (a terminal's OSC 0/2, a page's `<title>`).
    /// Views show ``displayTitle``; reading this one redraws on every spinner frame.
    public internal(set) var title: String
    /// The title's text without a terminal's leading status glyphs (``TerminalTitle``);
    /// a browser's title as is. Assigned only when the words change.
    public internal(set) var titleText: String
    /// What a terminal title's leading glyph said (a spinner: working); nil for none.
    public internal(set) var titleActivity: TerminalTitle.Activity?
    public internal(set) var size: CellSize?
    public internal(set) var dead: Bool
    /// Whether the terminal's shell runs (R41); nil for browsers and older daemons.
    public internal(set) var terminalState: TerminalTabState?
    /// How a dead terminal ended (R41): the banner names this reason.
    public internal(set) var end: TerminalTabEnd?
    /// A kept tab's keep-layout record (`end-terminals-keep-layout-v1`): its terminal ended at
    /// Quit's End Sessions, Keep Layout and this launch restarts it.
    public internal(set) var relaunch: TabRelaunch?
    public internal(set) var notification: TabNotification? { didSet { refreshUnread() } }
    public internal(set) var url: String?
    public internal(set) var pinned: Bool
    /// The page a pinned browser tab was pinned on (Back to Pinned Page).
    public internal(set) var pinnedURL: String?
    /// The daemon's cwd, else the folder the shell last reported to this
    /// app's surface (`noteTerminalDirectory`): the pinned daemon clears its
    /// own on a `kitty-shell-cwd://` report.
    public internal(set) var cwd: String?
    public internal(set) var gitBranch: String?
    public internal(set) var gitDetached: Bool
    public internal(set) var browserEngine: String?
    /// A frontend browser tab's browser profile (`frontend-browser-tab-profile-v1` moves it in place).
    public internal(set) var browserProfileID: String?
    public internal(set) var faviconURL: String?
    public internal(set) var isFrontendOwned: Bool
    public internal(set) var tabGroup: TabGroupID?
    public internal(set) var agent: AgentStatus?
    /// What the tab's agent is touching now; nil when it is not acting (`agent-presence-v1`).
    public internal(set) var presence: AgentPresence?
    /// Browser page zoom or terminal font scale saved on the tab record;
    /// nil = 1 (daemon state resources).
    public internal(set) var zoom: Double?
    /// The icon the user set on the tab record (`tab.update {icon}`; the shared icon
    /// wire string: one emoji or an SF Symbol name). Nil shows the tab kind's icon.
    public internal(set) var userIcon: String?
    /// The device a browser tab emulates, as the daemon resolved it
    /// (`extra.emulation`, browser-devices-v1); the engine applies it as is.
    public internal(set) var emulation: JSONValue?
    /// Marked unread by hand (Mark Tab Unread, `tab-mark-unread-v1`): a flag on the tab record
    /// in the daemon, apart from ``notification``. Every client shows it; a client clears it
    /// when the person views the tab. This client's own write shows at once
    /// (``expectMarkedUnread(_:)``) and the record's echo confirms it.
    public private(set) var markedUnread = false
    /// The mark as the daemon's tab record says it.
    @ObservationIgnored private var recordMarkedUnread = false
    /// A mark or clear this client sent that the record has not echoed yet.
    @ObservationIgnored private var pendingMarkedUnread: Bool?

    /// Shows `marked` now, before the daemon's `tab.update` answers: the
    /// round trip (hundreds of ms on a busy daemon) is never on the visible
    /// path of Mark Tab Read/Unread. The record's echo of `marked` settles it.
    public func expectMarkedUnread(_ marked: Bool) {
        pendingMarkedUnread = marked
        publishMarkedUnread()
    }

    /// Rolls back ``expectMarkedUnread(_:)`` when the write of `marked`
    /// failed. A newer pending value (a second toggle) stays.
    public func dropExpectedMarkedUnread(_ marked: Bool) {
        guard pendingMarkedUnread == marked else { return }
        pendingMarkedUnread = nil
        publishMarkedUnread()
    }

    /// Counts the times ``markedUnread`` turned on: each new mark is a new unread, so a ring
    /// dismissed for an earlier mark shows again. Changes only with ``markedUnread``, which
    /// observers already follow.
    @ObservationIgnored public private(set) var markedUnreadGeneration: UInt64 = 0

    private func publishMarkedUnread() {
        let shown = pendingMarkedUnread ?? recordMarkedUnread
        guard markedUnread != shown else { return }
        if shown { markedUnreadGeneration &+= 1 }
        markedUnread = shown
    }
    /// The tab's fit as given (`extra.emulation.fit.value`: "16:9" or "1280", browser-fit-v1), nil for none.
    public var fitValue: String? { emulation?["mode"]?.stringValue == "fit" ? emulation?["fit"]?["value"]?.stringValue ?? "16:9" : nil }
    /// A browser tab's saved back URLs (oldest first) and forward URLs
    /// (nearest first).
    public internal(set) var backURLs: [String] = []
    public internal(set) var forwardURLs: [String] = []
    /// The terminal's OSC 9;4 progress as the daemon parses it, mounted or
    /// not (`TerminalSnapshot.extra.progress`).
    public internal(set) var progress: TerminalProgressReport?
    /// The terminal's OSC 7501 program status records (`extra.program_status`).
    public internal(set) var programStatus: [ProgramStatusRecord] = []
    /// When the terminal's running shell command started (`extra.busy.since_ms`: the daemon's
    /// OSC 133 C..D fact), nil at a prompt. How long it must run to show is the client's call.
    public internal(set) var commandSinceMs: UInt64?
    /// This clock's time when `commandSinceMs` arrived: another machine's daemon may run ahead.
    @ObservationIgnored public private(set) var commandSeenAt: Date?
    /// Bumped when `recheckCommand(after:)` fires: whoever read the command's age reads it again.
    public private(set) var commandRecheck = 0
    @ObservationIgnored private var commandTimer: DemandTimer?
    /// Since when the shell sits at its prompt (`extra.prompt.since_ms`: OSC 133 A until C), nil while
    /// a command runs and for a shell without integration.
    public internal(set) var promptSinceMs: UInt64?
    /// This clock's time when `promptSinceMs` arrived: another machine's daemon may run ahead.
    @ObservationIgnored public private(set) var promptSeenAt: Date?
    /// When the terminal last printed (`extra.last_output.at_ms`).
    public internal(set) var lastOutputMs: UInt64?
    /// This clock's time when `lastOutputMs` arrived: another machine's daemon may run ahead.
    @ObservationIgnored public private(set) var lastOutputSeenAt: Date?
    /// The terminal a remote-terminal tab references (on another session).
    public internal(set) var remote: RemoteTerminalRef?
    /// What a `.conversation` tab shows (`TabSnapshot.conversation`). Stored and observed: a
    /// chat picked in an open tab changes only this, and the control snapshot must hear it (cx-sy3w1).
    public internal(set) var conversation: ConversationTabRef? { didSet { refreshUnread() } }
    /// The app an app tab shows (`TabSnapshot.app`), observed like ``conversation``.
    public internal(set) var app: AppTabRef?
    /// Last snapshot, for fields the record does not surface. Views should
    /// read the typed fields; this one changes whenever any field does.
    @ObservationIgnored public private(set) var snapshot: TabSnapshot
    @ObservationIgnored private var observedCwd: String?
    public var displayTitle: String {
        if let name, !name.isEmpty { return name }
        return titleText
    }

    /// Whether the tab holds an unread notification. A notification this
    /// client read (``expectNotificationRead()``) shows read before the
    /// daemon's echo.
    public var hasUnread: Bool {
        guard let notification, notification.unread else { return false }
        return notification.notification != readingNotification
    }

    /// The notification this client acknowledged that the tree still shows
    /// unread (the ack's round trip). A newer notification is not covered.
    public private(set) var readingNotification: NotificationID? { didSet { refreshUnread() } }

    /// Shows the tab's unread notification read now, before the daemon's
    /// `ack-tab-notifications` answers. The tree's echo settles it.
    public func expectNotificationRead() {
        guard let notification, notification.unread else { return }
        readingNotification = notification.notification
    }

    /// Rolls back ``expectNotificationRead()`` when the acknowledge failed.
    public func dropExpectedNotificationRead() {
        if readingNotification != nil { readingNotification = nil }
    }

    /// The tree's notification marker arrived: a read or replaced
    /// notification settles a pending read.
    private func settleReadingNotification() {
        guard let reading = readingNotification else { return }
        if notification?.notification != reading || notification?.unread != true { readingNotification = nil }
    }

    /// What this tab adds to its pane's unread count (``UnreadTally``), as last counted.
    @ObservationIgnored private(set) var unreadMark: UnreadTally.Mark = .none
    /// The pane that counts this tab (the last one whose tabs held it).
    @ObservationIgnored weak var unreadPane: PaneModel?

    private func currentUnreadMark() -> UnreadTally.Mark {
        guard hasUnread else { return .none }
        return .unread(conversation: kind == .conversation ? conversation?.conversation : nil)
    }

    /// A field the unread count reads changed: recounts the pane when what the tab adds changed.
    private func refreshUnread() {
        let mark = currentUnreadMark()
        guard mark != unreadMark else { return }
        unreadMark = mark
        unreadPane?.recountUnread()
    }

    /// Whether the tab shows as unread: an unread notification or the manual mark.
    /// Acknowledging reads only ``hasUnread``; this is for dots and badges.
    public var showsUnread: Bool { hasUnread || markedUnread }

    /// Public tab id (`tab_…`) on registry daemons. Stored and observed: a
    /// tab can get its id in a later snapshot of the same surface, and an
    /// observer that found no tab by this id must hear it.
    public internal(set) var resourceID: ResourceID?

    /// The acpmux session record of an agent chat tab (a conversation tab with an agent session
    /// source, `agent-session-tabs-v1`); nil for every other tab.
    public var agentSession: AgentSessionRef? {
        kind == .conversation ? conversation?.agentSession : nil
    }

    /// The app an app tab shows (a frontend tab of an app workspace, `app-screens-v1`).
    public var appTab: AppTabRef? {
        kind == .browser ? app : nil
    }

    /// The page id of a page tab (a conversation tab with a page source, `page-tabs-v1`: the
    /// App Store, Settings); nil for every other tab.
    public var page: String? {
        kind == .conversation ? conversation?.page : nil
    }

    /// What a page tab shows (`page-tab-route-v1`); nil for none or any other tab.
    public var pageRoute: String? {
        kind == .conversation ? conversation?.route : nil
    }

    init(_ s: TabSnapshot) {
        id = Self.identity(s)
        snapshot = s
        resourceID = s.tabResourceID
        surface = s.surface
        terminalID = s.terminalID
        terminalIncarnation = s.terminalIncarnation
        terminalResourceID = s.terminalResourceID
        kind = s.kind
        name = s.name
        title = s.title
        let parsed = Self.parsedTitle(s.title, kind: s.kind)
        titleText = parsed.text
        titleActivity = parsed.activity
        size = s.size
        dead = s.dead
        terminalState = s.terminalState
        end = s.end
        relaunch = s.relaunch
        notification = s.notification
        url = s.url
        pinned = s.pinned
        pinnedURL = s.pinnedURL
        cwd = s.cwd
        gitBranch = s.gitBranch
        gitDetached = s.gitDetached
        browserEngine = s.browserEngine
        browserProfileID = s.browserProfileID
        faviconURL = s.faviconURL
        isFrontendOwned = s.isFrontendOwned
        tabGroup = s.tabGroup
        remote = s.remote
        conversation = s.conversation
        app = s.app
        unreadMark = currentUnreadMark()
        #if DEBUG || CMUX_BENCH_HOOKS
        // A traced new terminal's tab reached the store (its `tab-added`, or a resync's snapshot).
        if NewTerminalTrace.shared.isArmed, let terminal = s.terminalID {
            NewTerminalTrace.shared.tabAdded(terminal: terminal.rawValue, surface: s.surface.rawValue)
        }
        #endif
    }

    static func identity(_ s: TabSnapshot) -> String {
        s.tabResourceID?.rawValue ?? s.terminalID.map { "terminal:\($0.rawValue)" } ?? "surface:\(s.surface.rawValue)"
    }

    func update(_ s: TabSnapshot) {
        guard s != snapshot else { return }
        snapshot = s
        if resourceID != s.tabResourceID { resourceID = s.tabResourceID }
        if surface != s.surface { surface = s.surface }
        if terminalID != s.terminalID { terminalID = s.terminalID }
        if terminalIncarnation != s.terminalIncarnation { terminalIncarnation = s.terminalIncarnation }
        if terminalResourceID != s.terminalResourceID { terminalResourceID = s.terminalResourceID }
        if kind != s.kind { kind = s.kind }
        if name != s.name { name = s.name }
        applyTitle(s.title)
        if size != s.size { size = s.size }
        if dead != s.dead { dead = s.dead }
        if terminalState != s.terminalState { terminalState = s.terminalState }
        if end != s.end { end = s.end }
        if relaunch != s.relaunch { relaunch = s.relaunch }
        if notification != s.notification { notification = s.notification }
        settleReadingNotification()
        if url != s.url { url = s.url }
        if pinned != s.pinned { pinned = s.pinned }
        if pinnedURL != s.pinnedURL { pinnedURL = s.pinnedURL }
        refreshCwd()
        if gitBranch != s.gitBranch { gitBranch = s.gitBranch }
        if gitDetached != s.gitDetached { gitDetached = s.gitDetached }
        if browserEngine != s.browserEngine { browserEngine = s.browserEngine }
        if browserProfileID != s.browserProfileID { browserProfileID = s.browserProfileID }
        if faviconURL != s.faviconURL { faviconURL = s.faviconURL }
        if isFrontendOwned != s.isFrontendOwned { isFrontendOwned = s.isFrontendOwned }
        if tabGroup != s.tabGroup { tabGroup = s.tabGroup }
        if remote != s.remote { remote = s.remote }
        if conversation != s.conversation { conversation = s.conversation }
        if app != s.app { app = s.app }
    }

    /// Lays the daemon's tab record and terminal progress over the record.
    func applyState(_ record: SessionStateMirror.TabRecord?, progress: TerminalProgressReport?, programStatus: [ProgramStatusRecord] = [],
                    commandSinceMs: UInt64? = nil, promptSinceMs: UInt64? = nil, lastOutputMs: UInt64? = nil) {
        let record = record ?? SessionStateMirror.TabRecord()
        if zoom != record.zoom { zoom = record.zoom }
        if userIcon != record.icon { userIcon = record.icon }
        if emulation != record.emulation { emulation = record.emulation }
        recordMarkedUnread = record.markedUnread
        if pendingMarkedUnread == record.markedUnread { pendingMarkedUnread = nil }
        publishMarkedUnread()
        if backURLs != record.back { backURLs = record.back }
        if forwardURLs != record.forward { forwardURLs = record.forward }
        if self.progress != progress { self.progress = progress }
        if self.programStatus != programStatus { self.programStatus = programStatus }
        if self.commandSinceMs != commandSinceMs {
            commandSeenAt = commandSinceMs.map { _ in Date() }
            self.commandSinceMs = commandSinceMs
            commandTimer?.cancel()
        }
        if self.promptSinceMs != promptSinceMs {
            promptSeenAt = promptSinceMs.map { _ in Date() }
            self.promptSinceMs = promptSinceMs
        }
        if self.lastOutputMs != lastOutputMs {
            lastOutputSeenAt = lastOutputMs.map { _ in Date() }
            self.lastOutputMs = lastOutputMs
        }
    }

    /// Reads the running command's age again after `delay`: one one-shot timer per running command,
    /// armed by the status mapping while the command is younger than its threshold.
    public func recheckCommand(after delay: Duration) {
        let timer = commandTimer ?? DemandTimer(owner: "tab.command-busy")
        commandTimer = timer
        // A replace, not scheduleIfIdle: a lowered threshold moves the deadline earlier.
        timer.schedule(after: delay) { @MainActor [weak self] in self?.commandRecheck += 1 }
    }

    /// Point updates from surface events (no full snapshot).
    func setTitle(_ value: String) {
        applyTitle(value)
        snapshot.title = value
    }

    /// Assigns the raw title, and its text and activity only when they changed, so a
    /// spinner frame invalidates no view that reads ``displayTitle``.
    private func applyTitle(_ value: String) {
        if title != value { title = value }
        let parsed = Self.parsedTitle(value, kind: kind)
        if titleText != parsed.text { titleText = parsed.text }
        if titleActivity != parsed.activity { titleActivity = parsed.activity }
    }

    /// A terminal's title loses its leading status glyphs; a page's stays as the page wrote it.
    static func parsedTitle(_ raw: String, kind: TabKind) -> TerminalTitle {
        switch kind {
        case .pty, .remoteTerminal: TerminalTitle(raw: raw)
        default: TerminalTitle(text: raw)
        }
    }

    func setSize(_ value: CellSize) {
        if size != value { size = value }
        snapshot.size = value
    }

    func setAgent(_ value: AgentStatus?) {
        if agent != value { agent = value }
    }

    func setPresence(_ value: AgentPresence?) {
        if presence != value { presence = value }
    }

    func markDead() {
        if !dead { dead = true }
        snapshot.dead = true
    }

    func setPinned(_ value: Bool) {
        if pinned != value { pinned = value }
        snapshot.pinned = value
    }

    func setName(_ value: String?) {
        if name != value { name = value }
        snapshot.name = value
    }

    /// The folder the shell reported, already a path (`path(reported:)`).
    func setObservedCwd(_ value: String?) {
        guard observedCwd != value else { return }
        observedCwd = value
        refreshCwd()
    }

    /// The path of a folder the shell reported (OSC 7): a path, a `file://`
    /// URL, or a `kitty-shell-cwd://host/path` URL, whose path is raw (not
    /// percent-encoded).
    static func path(reported value: String) -> String? {
        var path: String? = value
        if value.hasPrefix("file://") {
            path = URL(string: value)?.path
        } else if value.hasPrefix("kitty-shell-cwd://") {
            let rest = value.dropFirst("kitty-shell-cwd://".count)
            let fromSlash = rest.drop { $0 != "/" }
            path = fromSlash.isEmpty ? nil : String(fromSlash)
        }
        // Only an absolute local path; a relative or `~` report says nothing usable.
        return path?.hasPrefix("/") == true ? path : nil
    }

    private func refreshCwd() {
        let value = snapshot.cwd ?? observedCwd
        if cwd != value { cwd = value }
    }
}
