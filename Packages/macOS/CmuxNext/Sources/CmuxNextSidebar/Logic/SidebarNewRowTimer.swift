public import AppKit
public import CmuxNextDesign
import CmuxNextSignposts
import QuartzCore

/// Per new workspace, the time from its create to the frame that first draws its sidebar row.
///
/// Every build: the `create.workspace` interval (``SignpostName/createWorkspace``), one async pair per create
/// that has a row (`os_signpost`, the MetricKit mirror and the trace ring's AB/AE). It begins when the create
/// names its workspace (``began(_:inputTimestamp:)``, in the press's turn) with the age of the press's own input
/// event in the top 24 bits of `arg0` (all ones for a script's create or one with no stamp), and ends at the
/// ``CommitBoundary`` after the turn whose list reload first listed the row in a window (``drew(in:listed:)``,
/// which every `SidebarListView.reload` runs). A create whose row goes before it was drawn (the create failed, a
/// close took it, it lists in no window: ``forget(_:)``), or that no list drew within ``staleAfter``, ends as
/// missed (`commit=missed`), so readers and MetricKit drop it. Every begin gets exactly one end. Chrome times a
/// new tab the same way: one async trace event from the input to the presented frame, closed by
/// `ContentToVisibleTimeReporter` (content/browser/renderer_host/visible_time_request_trigger.h).
///
/// Debug: `debug.new_workspace` records, per create, its row from the interval's begin (so the Debug rows and
/// the trace read the same start) to the frame its row is first drawn, as `SwitchFrameTimer` times a tab switch
/// (`input_ms`, `apply_ms`, `commit_ms`, `late_vsyncs`), and `walks`: the rows passes that walked every
/// workspace (`SidebarRowFeed.fill`) between the two. A new workspace's row is drawn from the press, before the
/// daemon creates it (the App's PendingWorkspaceRows), so it needs no walk: perf-gate.py's new_workspaces
/// scenario gates `walks` 0 for every create.
///
/// It is not `SwitchFrameTimer`'s signpost mode: a switch shows in its intent's turn (that turn's boundary ends
/// it, shown or not), while a create's row may list a turn or more later (a held change, a stand-in the daemon
/// replaces), so its end waits for the turn that lists it, bounded by ``staleAfter``.
@MainActor
public final class SidebarNewRowTimer {
    /// Runs a block once after the commit that ends this main run-loop turn.
    typealias Boundary = @MainActor (_ body: @escaping @MainActor (CommitBoundary.Outcome) -> Void) -> Void

    /// Its socket method reads and starts or stops this (the App's `debug.new_workspace`).
    public let timer = SwitchFrameTimer(owner: "debug.new_workspace")
    /// The rebuild count at each recorded create's begin, by workspace id.
    private var walksAtBegin: [WorkspaceID: Int] = [:]

    private struct Open {
        let serial: UInt64
        let interval: SignpostInterval
        /// ``now`` at the begin (``staleAfter``).
        let beganAt: TimeInterval
        /// Its row was listed: the boundary of that turn ends it.
        var ending = false
    }

    /// Creates whose row has not been listed and committed yet, by workspace id.
    private var open: [WorkspaceID: Open] = [:]
    private var lastSerial: UInt64 = 0
    /// The most creates open at once; a begin past it ends the oldest as missed.
    static let openLimit = 64
    /// A create no list drew within this many seconds ends as missed: its row lists in no window (its window
    /// closed, it had no slot), and a late listing must not end it as a long committed sample.
    static let staleAfter: TimeInterval = 10
    private let signposter: Signposter
    private let boundary: Boundary
    /// Uptime seconds, `NSEvent.timestamp`'s clock.
    private let now: @MainActor () -> TimeInterval

    public convenience init() {
        self.init(signposter: .create, boundary: { CommitBoundary().after($0) }, now: { CACurrentMediaTime() })
    }

    /// - Parameters:
    ///   - signposter: The create category's signposter (tests pass one on their own trace runtime).
    ///   - boundary: Runs an end after this turn's commit (tests fire it themselves).
    ///   - now: Uptime seconds now, on `NSEvent.timestamp`'s clock (tests move it).
    init(signposter: Signposter, boundary: @escaping Boundary, now: @escaping @MainActor () -> TimeInterval) {
        self.signposter = signposter
        self.boundary = boundary
        self.now = now
        timer.onStart = { [weak self] in self?.walksAtBegin = [:] }
    }

    /// How many creates wait for their row's commit (tests).
    var openCount: Int { open.count }

    /// The create of workspace `id` named it and its row is about to list: begins its `create.workspace` interval.
    ///
    /// - Parameters:
    ///   - id: The workspace's key, fixed at the press.
    ///   - inputTimestamp: The `NSEvent.timestamp` of the person's key or click that asked for it (the event the
    ///     action registry was dispatching, or the stamp a gate carried); nil for a script's, socket's or later
    ///     task's create, which writes no input age.
    public func began(_ id: String, inputTimestamp: TimeInterval?) {
        let key = WorkspaceID(id), beganAt = now()
        endStale(at: beganAt)
        if let superseded = open.removeValue(forKey: key) { end(key, superseded, .missed) }
        if open.count >= Self.openLimit, let oldest = open.min(by: { $0.value.serial < $1.value.serial }) {
            open[oldest.key] = nil
            end(oldest.key, oldest.value, .missed)
        }
        lastSerial &+= 1
        let age = inputTimestamp.flatMap { beganAt >= $0 ? (beganAt - $0) * 1_000 : nil } ?? -1
        let interval = signposter.beginCreateWorkspace(inputAgeMilliseconds: age)
        open[key] = Open(serial: lastSerial, interval: interval, beganAt: beganAt)
        guard timer.isRecording else { return }
        walksAtBegin[key] = Self.walks
        timer.began(key, at: Double(interval.beginUptimeNanos) / 1_000_000_000, inputTimestamp: inputTimestamp)
    }

    /// The row of workspace `id` went before it was drawn (its create failed, a close took it, it lists in no
    /// window): its interval ends as missed. One whose row was listed ends at its boundary as before.
    public func forget(_ id: String) {
        let key = WorkspaceID(id)
        if let create = open[key], !create.ending {
            open[key] = nil
            end(key, create, .missed)
        }
    }

    /// A list in `window` reloaded; `listed` says whether it lists a workspace now. Each open create it lists
    /// ends at this turn's commit boundary, once. O(open creates), never O(rows).
    func drew(in window: NSWindow?, listed: (WorkspaceID) -> Bool) {
        let recording = timer.isRecording && !walksAtBegin.isEmpty
        guard recording || !open.isEmpty else { return }
        endStale(at: now())
        for (key, create) in open where !create.ending && listed(key) {
            open[key]?.ending = true
            let serial = create.serial
            boundary { [weak self] outcome in self?.boundaryFired(key, serial: serial, outcome) }
        }
        guard recording else { return }
        for (key, walks) in walksAtBegin where listed(key) {
            walksAtBegin[key] = nil
            guard timer.isWaiting(key) else { continue }
            timer.shown(key, in: window, extra: ["walks": Double(Self.walks - walks)])
        }
    }

    private func boundaryFired(_ key: WorkspaceID, serial: UInt64, _ outcome: CommitBoundary.Outcome) {
        guard let create = open[key], create.serial == serial else { return }
        open[key] = nil
        signposter.end(.createWorkspace, create.interval, outcome)
    }

    /// Ends every create no list drew within ``staleAfter`` as missed.
    private func endStale(at time: TimeInterval) {
        func stale(_ create: Open) -> Bool { !create.ending && time - create.beganAt > Self.staleAfter }
        guard open.values.contains(where: stale) else { return }
        for (key, create) in open where stale(create) {
            open[key] = nil
            end(key, create, .missed)
        }
    }

    /// Ends `create`'s interval before its row was listed; its recorded row goes too.
    private func end(_ key: WorkspaceID, _ create: Open, _ outcome: CommitBoundary.Outcome) {
        signposter.end(.createWorkspace, create.interval, outcome)
        guard walksAtBegin.removeValue(forKey: key) != nil else { return }
        timer.forget(key)
    }

    private static var walks: Int { SidebarPerfCounters.count(.rebuilds) }
}
