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

    private static let launchLog = Logger(subsystem: "com.cmuxterm.app.next", category: "window-rules")
}
