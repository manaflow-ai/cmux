public import CmuxNextDaemon
import CmuxNextCompat
import os

/// The launch snapshot's standing once the live tree applied (cmux-window-rules `launch`, cmuxterm-hq#12660).
///
/// The launch window is drawn from the snapshot file the defaults name (`cmuxNext.launchSnapshotPath.<session>`)
/// before the daemon answers. That file can belong to another session: a daemon state reset that kept the default, a
/// backup that restored only one of the two, two copies of a build with one bundle id. The window then showed
/// workspaces the daemon does not have, and the launch made a New Tab workspace to stand in for them instead of
/// showing Home. `WindowManager.restore` asks here once the live tree applied: a stale snapshot is dropped from the
/// launch window, so the restore goes on as a launch with nothing to restore, which lands on Home. A current one
/// changes nothing.
extension WindowRules {
    /// What the app knows of the snapshot it drew before the daemon answered, and of the daemon that answered.
    public nonisolated struct LaunchSnapshotFacts: Encodable, Equatable, Sendable {
        /// The snapshot tree's registry id (its session); nil from an older daemon's file.
        public var snapshotSession: String?
        /// The live daemon's registry id.
        public var liveSession: String?
        /// The workspace the launch window showed from the snapshot.
        public var shown: String?
        /// Every workspace the launch window listed from the snapshot.
        public var listed: [String]
        /// Those of `shown` and `listed` the live tree has.
        public var live: [String]

        public init(snapshotSession: String?, liveSession: String?, shown: String?, listed: [String], live: [String]) {
            self.snapshotSession = snapshotSession
            self.liveSession = liveSession
            self.shown = shown
            self.listed = listed
            self.live = live
        }
    }

    /// Whether the snapshot is stale: written by another session, or showing workspaces the daemon lacks.
    /// False when the FFI does not answer (one pinned before `window_launch_snapshot_verdict`): the launch
    /// keeps what it drew, as before.
    public func launchSnapshotIsStale(_ facts: LaunchSnapshotFacts) -> Bool {
        struct Reply: Decodable { var verdict: String }
        guard let verdict = call("window_launch_snapshot_verdict", facts, as: Reply.self)?.verdict, verdict != "current" else { return false }
        Self.launchLog.notice("launch snapshot stale (\(verdict, privacy: .public)): launching as with nothing to restore")
        return true
    }

    /// ``launchSnapshotIsStale(_:)`` for the launch window: `listed` its snapshot workspaces (nil: it drew none, so
    /// nothing is stale), `shown` its shown one, `isLive` whether the live tree has a workspace.
    public func launchSnapshotIsStale(snapshot: String?, live: String?, shown: String?, listed: [String]?,
                                      isLive: (String) -> Bool) -> Bool {
        guard let listed else { return false }
        let named = Set(listed + (shown.map { [$0] } ?? []))
        return launchSnapshotIsStale(LaunchSnapshotFacts(snapshotSession: snapshot, liveSession: live, shown: shown, listed: listed,
                                                         live: named.filter(isLive).sorted()))
    }

    /// Where the person last was, from the daemon's saved front window: Home is said, never read off a missing tab.
    public nonisolated enum LastFront: Equatable, Sendable {
        /// No saved window: a true first launch.
        case nothing
        /// The home workspace, or classic Home's top page.
        case home
        case workspace(String, pane: String?, tab: String?)
    }

    /// The saved tab in the live tree: listed and running, listed with its process ended (the daemon relaunches it),
    /// or not listed.
    public nonisolated enum TabStanding: String, Encodable, Sendable { case live, ended, gone }

    /// Where the launch's front window lands (cmux-window-rules `launch::landing`).
    public nonisolated enum LaunchLanding: Equatable, Sendable {
        /// `why`: `firstLaunch`, `lastWasHome` or `unknownWorkspace`.
        case home(why: String)
        case workspace(String, pane: String?, tab: String?)
    }

    /// Where a launch lands (Leo 2026-11-18: "if it's not first time and the user was on a workspace and a tab, obv
    /// just take them there"; "ofc reopening home if they were prev on home is fine"). Nil when the FFI does not
    /// answer (one pinned before `window_launch_landing`): the restore keeps what it showed, as before.
    public func launchLanding(last: LastFront, workspaceLive: Bool, tab: TabStanding) -> LaunchLanding? {
        struct Last: Encodable { var kind: String; var workspace: String?; var pane: String?; var tab: String? }
        struct Facts: Encodable { var last: Last; var workspaceLive: Bool; var tab: TabStanding }
        struct Reply: Decodable { var kind: String; var why: String?; var workspace: String?; var pane: String?; var tab: String? }
        let encoded: Last = switch last {
        case .nothing: Last(kind: "nothing")
        case .home: Last(kind: "home")
        case let .workspace(id, pane, tab): Last(kind: "workspace", workspace: id, pane: pane, tab: tab)
        }
        guard let reply = call("window_launch_landing", Facts(last: encoded, workspaceLive: workspaceLive, tab: tab), as: Reply.self)
        else { return nil }
        if reply.kind == "workspace", let workspace = reply.workspace { return .workspace(workspace, pane: reply.pane, tab: reply.tab) }
        return reply.kind == "home" ? .home(why: reply.why ?? "") : nil
    }

    /// ``launchLanding(last:workspaceLive:tab:)`` for the relaunch's front saved window `record`, `workspace` the live
    /// tree's lookup. Its top page Home, or the home workspace, is Home; else its workspace and the tab its focused pane
    /// showed (a tab whose process ended after a reboot is `ended`: the daemon relaunches it). Nil for a window on
    /// another top page (Settings, History), which reopens on that page as saved, and when the FFI does not answer.
    @MainActor
    public func launchLanding(front record: WindowRecord, workspace: (String) -> WorkspaceModel?) -> LaunchLanding? {
        struct Saved: Encodable { var dead, relaunch: Bool }
        struct Live: Encodable { var home: Bool; var tab: Saved? }
        struct Facts: Encodable { var page, workspace, pane, tab: String?; var live: Live? }
        struct Landing: Decodable { var kind: String; var why: String?; var workspace: String?; var pane: String?; var tab: String? }
        struct Reply: Decodable { var landing: Landing? }
        let id = record.workspaceKey?.rawValue, pane = id.flatMap { record.focusedPanes[$0] } ?? record.focusedPane
        let tab = pane.flatMap { record.selectedTabs[$0] }
        let live = id.flatMap(workspace).map { live in
            let saved = live.screens.lazy.flatMap(\.panes).first { $0.id == pane }?.tabs.first { $0.id == tab }
            return Live(home: live.isAnyHome, tab: saved.map { Saved(dead: $0.dead, relaunch: $0.relaunch != nil) })
        }
        let facts = Facts(page: record.page, workspace: id, pane: pane, tab: tab, live: live)
        guard let landing = call("window_launch_front_landing", facts, as: Reply.self)?.landing else { return nil }
        if landing.kind == "workspace", let workspace = landing.workspace {
            return .workspace(workspace, pane: landing.pane, tab: landing.tab)
        }
        return landing.kind == "home" ? .home(why: landing.why ?? "") : nil
    }

    /// What a relaunch's pending Home landing reads (cmux-window-rules `launch::pending_home`): the saved front window
    /// it is for, the active window, whether the front window is open, Home's workspace is listed, and whether the front
    /// window shows another workspace or page than the restore did, now (`moved`) or at any time since
    /// (`movedSinceRestore`, latched by the window: leaving and coming back still drops the landing).
    public nonisolated struct PendingHome: Encodable, Equatable, Sendable {
        public var window: String
        public var active: String?
        public var windowOpen: Bool
        public var homeReady: Bool
        public var moved: Bool
        public var movedSinceRestore: Bool

        public init(window: String, active: String?, windowOpen: Bool, homeReady: Bool, moved: Bool, movedSinceRestore: Bool) {
            (self.window, self.active, self.windowOpen, self.homeReady) = (window, active, windowOpen, homeReady)
            (self.moved, self.movedSinceRestore) = (moved, movedSinceRestore)
        }
    }

    /// Lands Home for a relaunch whose saved workspace the daemon lacks, once Home's workspace is listed: no timer,
    /// each change of what `facts` reads asks the rule again. `land` gets the saved front window (never the active
    /// one). Ends when it landed, or when the window closed or the person moved on (the rule's `stop`), or at once
    /// when the FFI does not answer (one pinned before `window_launch_pending_home`).
    @MainActor
    public func landHomeWhenReady(_ facts: @escaping @MainActor @Sendable () -> PendingHome, land: @escaping @MainActor (String) -> Void) {
        struct Reply: Decodable { var step: String; var window: String? }
        Task { @MainActor in
            for await read in ObservationStream(facts) {
                guard let reply = call("window_launch_pending_home", read, as: Reply.self), reply.step != "stop" else { return }
                if reply.step == "land", let window = reply.window { return land(window) }
            }
        }
    }

    /// What the app knows when a launch decides whether it opens something fresh (cmux-window-rules `launch::FreshFacts`).
    public nonisolated struct FreshFacts: Encodable, Equatable, Sendable {
        /// The tree has no workspace of the person's own (`needsFirstWorkspace`, read with the Home `ensure_home` named).
        public var emptyTree: Bool
        /// Saved windows exist and none of them is open (#31514).
        public var noSavedWindowOpen: Bool
        public var classicHome: Bool
        /// `ensure_home` named a Home workspace.
        public var homeEnsured: Bool
        /// An `ensure_home` is in flight, or this launch ensures Home and none answered yet.
        public var homeNotEnsuredYet: Bool

        public init(emptyTree: Bool, noSavedWindowOpen: Bool, classicHome: Bool, homeEnsured: Bool, homeNotEnsuredYet: Bool) {
            self.emptyTree = emptyTree
            self.noSavedWindowOpen = noSavedWindowOpen
            self.classicHome = classicHome
            self.homeEnsured = homeEnsured
            self.homeNotEnsuredYet = homeNotEnsuredYet
        }
    }

    /// What a launch opens fresh (cmux-window-rules `launch::fresh_landing`).
    public nonisolated enum FreshLanding: String, Decodable, Sendable {
        /// Home, the Chief's workspace.
        case home
        /// A new workspace on its New Tab page.
        case newTab
        /// Nothing yet: ask again once the facts change.
        case waitForHome
        /// Nothing fresh: the saved windows reopen (``launchLanding(front:workspace:)``).
        case saved
    }

    /// What a launch opens fresh (Leo 2026-11-18: "fresh startup opening home is obv fine but if it's not first time
    /// and the user was on a workspace and a tab, obv just take them there"): Home or a New Tab workspace for an empty
    /// tree, a New Tab workspace when no saved window is open, and nothing while Home is not ensured yet. When the FFI
    /// does not answer (one pinned before `window_launch_fresh_landing`), the launch's path before the rule: it waited
    /// only for an `ensure_home` in flight (`ensureInFlight`), not for one this launch had not asked yet.
    public func freshLanding(_ facts: FreshFacts, ensureInFlight: Bool) -> FreshLanding {
        struct Reply: Decodable { var kind: FreshLanding }
        if let reply = call("window_launch_fresh_landing", facts, as: Reply.self) { return reply.kind }
        if ensureInFlight { return .waitForHome }
        if !facts.emptyTree { return facts.noSavedWindowOpen ? .newTab : .saved }
        return facts.classicHome || !facts.homeEnsured ? .newTab : .home
    }

    private static let launchLog = Logger(subsystem: "com.cmuxterm.app.next", category: "window-rules")
}
