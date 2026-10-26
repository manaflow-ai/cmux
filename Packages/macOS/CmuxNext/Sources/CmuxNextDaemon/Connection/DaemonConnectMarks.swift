import CmuxNextCompat

/// The launch's daemon connect milestones, as the app sees them: each is sent to the sink the first time it happens
/// and never again, so a reconnect, a respawn after a crash or a second snapshot adds nothing (Chrome records each
/// startup milestone once per browser start, components/startup_metric_utils/browser/startup_metric_utils.cc).
/// The recurring per-step marks (`daemon.connect_start`, `daemon.identify_end`, ...) stay ``DaemonLaunchTimings``'s.
/// Marks come from any thread.
public final class DaemonConnectMarks: Sendable {
    /// The milestones in launch order; their names are bench-startup.py's rows.
    public enum Milestone: String, CaseIterable, Sendable {
        /// `main` began the first connect attempt (``DaemonPrestart``).
        case connectStarted = "daemon.connect_started"
        /// That attempt started a daemon: `server ensure` answered `started` (a warm launch has none).
        case spawned = "daemon.spawned"
        /// The daemon answered the handshake (identify, client info, subscribe).
        case identified = "daemon.identified"
        /// The first snapshot (workspace tree) arrived.
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

    private let fired = Mutex<UInt8>(0)
    private let sink: @Sendable (String) -> Void

    /// - Parameter sink: Receives each milestone's name once (the app passes its launch timings); the default
    ///   records nothing.
    public init(sink: @escaping @Sendable (String) -> Void = { _ in }) {
        self.sink = sink
    }

    /// Sends `milestone` to the sink unless it was sent before.
    public func mark(_ milestone: Milestone) {
        let first = fired.withLock { fired -> Bool in
            guard fired & milestone.bit == 0 else { return false }
            fired |= milestone.bit
            return true
        }
        if first { sink(milestone.rawValue) }
    }
}
