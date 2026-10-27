import CmuxNextCompat
public import Foundation

/// The launch's daemon connect milestones, as the app sees them: each is sent to the sink once, and only while the
/// launch's startup connect runs (Chrome records each startup milestone once per browser start,
/// components/startup_metric_utils/browser/startup_metric_utils.cc). The startup connect ends when the app attaches
/// a connection (``attach(_:)``) or gives up (``close()``); a reconnect, a respawn after a crash or a later snapshot
/// adds nothing. `identified` and `snapshot_received` describe the attached connection only: a connection's marks
/// wait, with their times, until it is attached, and an attempt that failed or was handed off to a newer build
/// sends none. The recurring per-step marks (`daemon.connect_start`, `daemon.identify_end`, ...) stay
/// ``DaemonLaunchTimings``'s. Marks come from any thread.
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

        /// Whether `milestone` goes out now; it never goes out twice.
        mutating func claim(_ milestone: Milestone) -> Bool {
            guard sent & milestone.bit == 0 else { return false }
            sent |= milestone.bit
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
        let send = state.withLock { state -> Bool in
            if let attached = state.attached {
                guard attached === connection else { return false }
                return state.claim(milestone)
            }
            guard !state.closed else { return false }
            if !state.held.contains(where: { $0.connection === connection && $0.milestone == milestone }) {
                state.held.append(Held(connection: connection, milestone: milestone, date: now))
            }
            return false
        }
        if send { sink(milestone.rawValue, now) }
    }

    /// The startup connect attached `connection`, which is identified (its handshake is done): sends its kept marks
    /// with their times, `identified` now when it had none, ends the window for every other mark, and fetches its
    /// first snapshot (``DaemonConnection/prefetchSnapshot(onReceived:)``; an attempt's prefetch already running is
    /// kept, and its arrival is marked through ``mark(_:of:)``).
    public func attach(_ connection: DaemonConnection) async {
        let now = Date()
        let due = state.withLock { state -> [(Milestone, Date)] in
            guard !state.closed else { return [] }
            state.closed = true
            state.attached = connection
            var kept = state.held.filter { $0.connection === connection }.map { ($0.milestone, $0.date) }
            state.held.removeAll()
            if !kept.contains(where: { $0.0 == .identified }) { kept.insert((.identified, now), at: 0) }
            var due: [(Milestone, Date)] = []
            for (milestone, date) in kept {
                if state.claim(milestone) { due.append((milestone, date)) }
            }
            return due
        }
        for (milestone, date) in due { sink(milestone.rawValue, date) }
        await connection.prefetchSnapshot(onReceived: { self.mark(.snapshotReceived, of: connection) })
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
