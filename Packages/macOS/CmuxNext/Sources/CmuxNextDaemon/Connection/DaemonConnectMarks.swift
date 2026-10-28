import CmuxNextCompat
public import Foundation

/// The launch's daemon connect milestones, as the app sees them: each is sent to the sink once, and only while the
/// launch's startup connect runs (Chrome records each startup milestone once per browser start,
/// components/startup_metric_utils/browser/startup_metric_utils.cc). The startup connect ends when the app attaches
/// a connection (``attach(_:)``) or gives up (``close()``); a reconnect, a respawn after a crash or a later snapshot
/// adds nothing. `identified` and `snapshot_received` describe the attached connection only: a connection's marks
/// wait, with their times, until it is attached, and an attempt that failed or was handed off to a newer build
/// sends none. When this launch spawned the attached daemon, its own start (``DaemonStartupMarks``) follows its first
/// snapshot, each step at the daemon's time. The recurring per-step marks (`daemon.connect_start`,
/// `daemon.identify_end`, ...) stay ``DaemonLaunchTimings``'s. Marks come from any thread.
public final class DaemonConnectMarks: Sendable {
    /// The milestones in launch order; their names are bench-startup.py's rows.
    public enum Milestone: String, CaseIterable, Sendable {
        /// `main` began the first connect attempt (``DaemonPrestart``), or the service did without one.
        case connectStarted = "daemon.connect_started"
        /// A startup attempt started a daemon: `server ensure` answered `started` (a warm launch has none).
        case spawned = "daemon.spawned"
        /// The attached daemon answered the handshake (identify, client info, subscribe).
        case identified = "daemon.identified"
        /// The attached daemon's first snapshot (workspace tree) arrived.
        case snapshotReceived = "daemon.snapshot_received"

        var bit: UInt8 {
            switch self {
            case .connectStarted: 1
            case .spawned: 2
            case .identified: 4
            case .snapshotReceived: 8
            }
        }
    }

    private struct Held {
        let connection: DaemonConnection
        let milestone: Milestone
        let date: Date
    }

    private struct State {
        var sent: UInt8 = 0
        /// The startup connect ended: only ``attached``'s marks still go out.
        var closed = false
        var attached: DaemonConnection?
        var held: [Held] = []
        var daemonStartRead = false

        /// Whether `milestone` goes out now; it never goes out twice.
        mutating func claim(_ milestone: Milestone) -> Bool {
            guard sent & milestone.bit == 0 else { return false }
            sent |= milestone.bit
            return true
        }

        /// Whether the attached daemon's own start is read now: once, after its first snapshot, and only when this
        /// launch spawned it (a warm launch's daemon started before the launch).
        mutating func claimDaemonStart(after milestone: Milestone) -> Bool {
            guard milestone == .snapshotReceived, sent & Milestone.spawned.bit != 0, !daemonStartRead else { return false }
            daemonStartRead = true
            return true
        }
    }

    private let state = Mutex(State())
    private let sink: @Sendable (String, Date) -> Void

    /// - Parameter sink: Receives each milestone's name once, with the time it happened (the app passes its launch
    ///   timings); the default records nothing.
    public init(sink: @escaping @Sendable (String, Date) -> Void = { _, _ in }) {
        self.sink = sink
    }

    /// Sends a launch-wide milestone (`connectStarted`, `spawned`) unless it was sent before or the startup connect
    /// ended.
    public func mark(_ milestone: Milestone) {
        let now = Date()
        let send = state.withLock { state -> Bool in
            guard !state.closed else { return false }
            return state.claim(milestone)
        }
        if send { sink(milestone.rawValue, now) }
    }

    /// Records `connection`'s `identified` or `snapshotReceived`: kept with its time until ``attach(_:)`` takes that
    /// connection, sent at once when it is the attached one, dropped for any other.
    public func mark(_ milestone: Milestone, of connection: DaemonConnection) {
        let now = Date()
        let (send, readStart) = state.withLock { state -> (Bool, Bool) in
            if let attached = state.attached {
                guard attached === connection, state.claim(milestone) else { return (false, false) }
                return (true, state.claimDaemonStart(after: milestone))
            }
            guard !state.closed else { return (false, false) }
            if !state.held.contains(where: { $0.connection === connection && $0.milestone == milestone }) {
                state.held.append(Held(connection: connection, milestone: milestone, date: now))
            }
            return (false, false)
        }
        if send { sink(milestone.rawValue, now) }
        if readStart { readDaemonStart(of: connection) }
    }

    /// The startup connect attached `connection`, which is identified (its handshake is done): sends its kept marks
    /// with their times, `identified` now when it had none, ends the window for every other mark, and fetches its
    /// first snapshot (``DaemonConnection/prefetchSnapshot(onReceived:)``; an attempt's prefetch already running is
    /// kept, and its arrival is marked through ``mark(_:of:)``).
    public func attach(_ connection: DaemonConnection) async {
        let now = Date()
        let (due, readStart) = state.withLock { state -> ([(Milestone, Date)], Bool) in
            guard !state.closed else { return ([], false) }
            state.closed = true
            state.attached = connection
            var kept = state.held.filter { $0.connection === connection }.map { ($0.milestone, $0.date) }
            state.held.removeAll()
            if !kept.contains(where: { $0.0 == .identified }) { kept.insert((.identified, now), at: 0) }
            var due: [(Milestone, Date)] = []
            var readStart = false
            for (milestone, date) in kept {
                guard state.claim(milestone) else { continue }
                due.append((milestone, date))
                if state.claimDaemonStart(after: milestone) { readStart = true }
            }
            return (due, readStart)
        }
        for (milestone, date) in due { sink(milestone.rawValue, date) }
        if readStart { readDaemonStart(of: connection) }
        await connection.prefetchSnapshot(onReceived: { self.mark(.snapshotReceived, of: connection) })
    }

    /// Reads the attached daemon's own start (``DaemonStartupMarksRequest``) and sends each step with the daemon's
    /// time, after `daemon.main_start`. A daemon without `startup-marks-v1` is not asked and sends none.
    private func readDaemonStart(of connection: DaemonConnection) {
        let sink = sink
        // task-owner: one read per launch, after the first snapshot; it ends with its reply or the connection
        Task {
            guard let marks = try? await connection.request(DaemonStartupMarksRequest()).startupMarks else { return }
            for (name, date) in marks.launchMarks { sink(name, date) }
        }
    }

    /// Whether a startup attempt started a daemon (``Milestone/spawned`` went out): false when the launch found the
    /// daemon running, as after the app alone ended (`kill -9`, a crash), whose terminals kept running in it.
    public var startedDaemon: Bool {
        state.withLock { $0.sent & Milestone.spawned.bit != 0 }
    }

    /// The startup connect gave up (cancelled, or a permanent failure): nothing more is sent.
    public func close() {
        state.withLock { state in
            state.closed = true
            state.held.removeAll()
        }
    }

    /// `launcher`'s endpoint provider for a startup connection: an `ensure` that started a daemon marks `spawned`.
    public func endpointProvider(of launcher: DaemonLauncher) -> DaemonConnection.EndpointProvider {
        launcher.spawnObservingEndpointProvider(onSpawned: { self.mark(.spawned) })
    }
}
