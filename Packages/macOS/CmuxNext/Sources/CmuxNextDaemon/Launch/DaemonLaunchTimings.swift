public import Foundation
import CmuxNextCompat
import CmuxNextSignposts

/// Marks of the app's daemon connection (login environment, `server ensure`,
/// connect, handshake, and the store resyncs and terminal attaches that recur
/// after it) for the App's `debug.timings` and the trace: each mark is one
/// ``SignpostName/daemonStep`` event, every time it happens. The App's receiver
/// keeps only the first time of each name as a launch mark. Marks come from
/// any thread. The first connect starts in `main`, before the App installs its
/// receiver, so marks are kept with their time until then.
public final class DaemonLaunchTimings: Sendable {
    public static let shared = DaemonLaunchTimings()
    private struct State {
        var sink: (@Sendable (String, Date) -> Void)?
        var early: [(String, Date)] = []
    }

    /// The marks of this module, in their fixed ring order: the `arg0` of a ``SignpostName/daemonStep`` record is
    /// the mark's position + 1 (0 for a name outside the list). A new mark goes at the end, so older rings decode.
    enum Step: String, CaseIterable {
        case binaryResolved = "daemon.binary_resolved"
        case loginEnvironmentStart = "daemon.login_env_start"
        case loginEnvironmentEnd = "daemon.login_env_end"
        case ensureStart = "daemon.ensure_start"
        case ensureEnd = "daemon.ensure_end"
        case statusStart = "daemon.status_start"
        case statusEnd = "daemon.status_end"
        case rememberedSocket = "daemon.remembered_socket"
        case connectStart = "daemon.connect_start"
        case endpointResolved = "daemon.endpoint_resolved"
        case socketConnected = "daemon.socket_connected"
        case identifyEnd = "daemon.identify_end"
        case handshakeEnd = "daemon.handshake_end"
        case snapshotStart = "daemon.snapshot_start"
        case snapshotEnd = "daemon.snapshot_end"
        case firstTreeApplied = "daemon.first_tree_applied"
        case attachStart = "terminal.attach_start"
        case attachEnd = "terminal.attach_end"
        case connectingStatusShown = "connecting_status_shown"
        // The launch's connect milestones (``DaemonConnectMarks``), one record each per launch.
        case connectStarted = "daemon.connect_started"
        case spawned = "daemon.spawned"
        case identified = "daemon.identified"
        case snapshotReceived = "daemon.snapshot_received"
        // The daemon's own start (``DaemonStartupMarks/launchMarks``), at the daemon's times, once per launch that
        // spawned it (``DaemonConnectMarks``).
        case daemonMainStart = "daemon.main_start"
        case daemonConfigLoaded = "daemon.config_loaded"
        case daemonOwnerPrepared = "daemon.owner_prepared"
        case daemonSocketBound = "daemon.socket_bound"
        case daemonMuxRestored = "daemon.mux_restored"
        case daemonOwnerEventLoop = "daemon.owner_event_loop"
        case daemonWebsocketReady = "daemon.websocket_ready"
        case daemonLaunchSnapshotWriterStarted = "daemon.launch_snapshot_writer_started"
        case daemonLifecycleReady = "daemon.lifecycle_ready"
        case daemonFirstIdentifyServed = "daemon.first_identify_served"

        /// The ring code of the mark `name`.
        static func traceCode(of name: String) -> UInt64 {
            allCases.firstIndex { $0.rawValue == name }.map { UInt64(clamping: $0) + 1 } ?? 0
        }
    }

    private let state = Mutex(State())
    private let signposter: Signposter

    /// - Parameter signposter: Where the ``SignpostName/daemonStep`` event of each mark goes (a `daemon` signposter).
    init(signposter: Signposter = Signposter(category: .daemon)) {
        self.signposter = signposter
    }

    /// Installs the receiver of marks (once, at launch) and hands it the
    /// marks made before.
    public func install(_ receiver: @escaping @Sendable (String, Date) -> Void) {
        let early = state.withLock { state -> [(String, Date)] in
            state.sink = receiver
            defer { state.early.removeAll() }
            return state.early
        }
        for (name, date) in early { receiver(name, date) }
    }

    public func mark(_ name: String) {
        mark(name, at: Date())
    }

    /// Marks `name` as having happened at `date` (a connect milestone kept until its connection was attached,
    /// ``DaemonConnectMarks``); its ring event is recorded now.
    public func mark(_ name: String, at date: Date) {
        signposter.event(.daemonStep, name, arg0: Step.traceCode(of: name))
        let receiver = state.withLock { state -> (@Sendable (String, Date) -> Void)? in
            if state.sink == nil, state.early.count < 64 { state.early.append((name, date)) }
            return state.sink
        }
        receiver?(name, date)
    }
}
