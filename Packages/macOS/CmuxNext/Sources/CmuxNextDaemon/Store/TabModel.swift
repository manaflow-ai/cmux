import Foundation
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
    public internal(set) var kind: TabKind
    public internal(set) var name: String?
    public internal(set) var title: String
    public internal(set) var size: CellSize?
    public internal(set) var dead: Bool
    /// Whether the terminal's shell runs (R41); nil for browsers and older daemons.
    public internal(set) var terminalState: TerminalTabState?
    /// How a dead terminal ended (R41): the banner names this reason.
    public internal(set) var end: TerminalTabEnd?
    public internal(set) var notification: TabNotification?
    public internal(set) var url: String?
    public internal(set) var pinned: Bool
    /// The daemon's cwd, else the folder the shell last reported to this
    /// app's surface (`noteTerminalDirectory`): the pinned daemon clears its
    /// own on a `kitty-shell-cwd://` report.
    public internal(set) var cwd: String?
    public internal(set) var gitBranch: String?
    public internal(set) var gitDetached: Bool
    public internal(set) var browserEngine: String?
    public internal(set) var faviconURL: String?
    public internal(set) var isFrontendOwned: Bool
    public internal(set) var tabGroup: TabGroupID?
    public internal(set) var agent: AgentStatus?
    /// Browser page zoom or terminal font scale saved on the tab record;
    /// nil = 1 (daemon state resources).
    public internal(set) var zoom: Double?
    /// The icon the user set on the tab record (`tab.update {icon}`; the shared icon
    /// wire string: one emoji or an SF Symbol name). Nil shows the tab kind's icon.
    public internal(set) var userIcon: String?
    /// A browser tab's saved back URLs (oldest first) and forward URLs
    /// (nearest first).
    public internal(set) var backURLs: [String] = []
    public internal(set) var forwardURLs: [String] = []
    /// The terminal's OSC 9;4 progress as the daemon parses it, mounted or
    /// not (`TerminalSnapshot.extra.progress`).
    public internal(set) var progress: TerminalProgressReport?
    /// The terminal's OSC 7501 program status records (`extra.program_status`).
    public internal(set) var programStatus: [ProgramStatusRecord] = []
    /// The terminal a remote-terminal tab references (on another session).
    public internal(set) var remote: RemoteTerminalRef?
    /// Last snapshot, for fields the record does not surface. Views should
    /// read the typed fields; this one changes whenever any field does.
    @ObservationIgnored public private(set) var snapshot: TabSnapshot
    @ObservationIgnored private var observedCwd: String?

    public var displayTitle: String {
        if let name, !name.isEmpty { return name }
        return title
    }

    public var hasUnread: Bool { notification?.unread == true }

    /// Public tab id (`tab_…`) on registry daemons.
    public var resourceID: ResourceID? { snapshot.tabResourceID }

    /// The acpmux session record of an agent chat tab (a conversation tab with an agent session
    /// source, `agent-session-tabs-v1`); nil for every other tab.
    public var agentSession: AgentSessionRef? {
        kind == .conversation ? snapshot.conversation?.agentSession : nil
    }

    /// The page id of a page tab (a conversation tab with a page source, `page-tabs-v1`: the
    /// App Store, Settings); nil for every other tab.
    public var page: String? {
        kind == .conversation ? snapshot.conversation?.page : nil
    }

    init(_ s: TabSnapshot) {
        id = Self.identity(s)
        snapshot = s
        surface = s.surface
        terminalID = s.terminalID
        terminalIncarnation = s.terminalIncarnation
        terminalResourceID = s.terminalResourceID
        kind = s.kind
        name = s.name
        title = s.title
        size = s.size
        dead = s.dead
        terminalState = s.terminalState
        end = s.end
        notification = s.notification
        url = s.url
        pinned = s.pinned
        cwd = s.cwd
        gitBranch = s.gitBranch
        gitDetached = s.gitDetached
        browserEngine = s.browserEngine
        faviconURL = s.faviconURL
        isFrontendOwned = s.isFrontendOwned
        tabGroup = s.tabGroup
        remote = s.remote
    }

    static func identity(_ s: TabSnapshot) -> String {
        s.tabResourceID?.rawValue ?? s.terminalID.map { "terminal:\($0.rawValue)" } ?? "surface:\(s.surface.rawValue)"
    }

    func update(_ s: TabSnapshot) {
        guard s != snapshot else { return }
        snapshot = s
        if surface != s.surface { surface = s.surface }
        if terminalID != s.terminalID { terminalID = s.terminalID }
        if terminalIncarnation != s.terminalIncarnation { terminalIncarnation = s.terminalIncarnation }
        if terminalResourceID != s.terminalResourceID { terminalResourceID = s.terminalResourceID }
        if kind != s.kind { kind = s.kind }
        if name != s.name { name = s.name }
        if title != s.title { title = s.title }
        if size != s.size { size = s.size }
        if dead != s.dead { dead = s.dead }
        if terminalState != s.terminalState { terminalState = s.terminalState }
        if end != s.end { end = s.end }
        if notification != s.notification { notification = s.notification }
        if url != s.url { url = s.url }
        if pinned != s.pinned { pinned = s.pinned }
        refreshCwd()
        if gitBranch != s.gitBranch { gitBranch = s.gitBranch }
        if gitDetached != s.gitDetached { gitDetached = s.gitDetached }
        if browserEngine != s.browserEngine { browserEngine = s.browserEngine }
        if faviconURL != s.faviconURL { faviconURL = s.faviconURL }
        if isFrontendOwned != s.isFrontendOwned { isFrontendOwned = s.isFrontendOwned }
        if tabGroup != s.tabGroup { tabGroup = s.tabGroup }
        if remote != s.remote { remote = s.remote }
    }

    /// Lays the daemon's tab record and terminal progress over the record.
    func applyState(_ record: SessionStateMirror.TabRecord?, progress: TerminalProgressReport?, programStatus: [ProgramStatusRecord] = []) {
        let record = record ?? SessionStateMirror.TabRecord()
        if zoom != record.zoom { zoom = record.zoom }
        if userIcon != record.icon { userIcon = record.icon }
        if backURLs != record.back { backURLs = record.back }
        if forwardURLs != record.forward { forwardURLs = record.forward }
        if self.progress != progress { self.progress = progress }
        if self.programStatus != programStatus { self.programStatus = programStatus }
    }

    /// Point updates from surface events (no full snapshot).
    func setTitle(_ value: String) {
        if title != value { title = value }
        snapshot.title = value
    }

    func setSize(_ value: CellSize) {
        if size != value { size = value }
        snapshot.size = value
    }

    func setAgent(_ value: AgentStatus?) {
        if agent != value { agent = value }
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
            path = rest.firstIndex(of: "/").map { String(rest[$0...]) }
        }
        // Only an absolute local path; a relative or `~` report says nothing usable.
        return path?.hasPrefix("/") == true ? path : nil
    }

    private func refreshCwd() {
        let value = snapshot.cwd ?? observedCwd
        if cwd != value { cwd = value }
    }
}
