public import CmuxSettings
internal import Dispatch
internal import Foundation
internal import os

/// The cmux control-socket listener: path reservation, bind/listen lifecycle,
/// the accept source with failure backoff/rearm, the socket-path monitor, and
/// the generation-counted recovery state machine, lifted faithfully from
/// `TerminalController`.
///
/// The server owns transport state only. Everything app-shaped — telemetry,
/// client command handling, restart scheduling, notifications — crosses the
/// ``SocketControlServerEvents`` seam, and accepted client connections are
/// surfaced through ``connections``.
///
/// ## Isolation design: state separated by its drivers
///
/// The listener's state has exactly three kinds of driver, and each kind owns
/// its own data; nothing needs an isolation bridge:
///
/// - **Lifecycle mutations** (start, stop, reserve, rearm claim) are all
///   driven from the main thread — app startup, `applicationWillTerminate`,
///   the updater relaunch hook, settings-driven restarts, and the recovery
///   callbacks all live there. The full ``ListenerState`` machine, including
///   the `DispatchSource` references and their suspend flags, is therefore
///   `@MainActor`: the legacy threading, made compiler-checked. Termination
///   teardown and startup path reservation stay synchronous for their
///   callers by construction.
/// - **Hot synchronous reads** (``isRunning`` polled per client read,
///   ``activeSocketPath(preferredPath:)`` on the surface-spawn path, listener
///   health) come from arbitrary threads and must not wait on anything.
///   Every mutation publishes a ``ListenerStateSnapshot`` to a lock-guarded
///   mirror; readers pay one short uncontended lock acquire, the same cost
///   profile as the stage-2 lock core.
/// - **The accept drain and path monitor** run on the listener queue as
///   `DispatchSource` handlers (the sanctioned carve-out; there is no
///   async-native replacement short of a transport rewrite). The handlers
///   are state-free: they capture the listener descriptor and generation as
///   values, consult the published snapshot for staleness, perform syscalls,
///   and yield connections. The one piece of genuinely accept-side state —
///   the consecutive-failure streak and a one-in-flight recovery latch — is
///   a tiny lock-guarded value (``AcceptRecoveryState``), because a
///   per-accept main-thread hop to maintain a counter would be wrong and a
///   hot errno must not spin while a recovery decision hops to main.
///   Recovery *decisions* (suspend/backoff/rearm) mutate lifecycle state, so
///   they hop to the main actor, guarded against staleness by generation,
///   descriptor, and suspension checks.
///
/// Suspend/resume balance note: the suspended flag and every `suspend()`/
/// `resume()`/`cancel()` call on the sources live on the main actor, one
/// isolation domain, so the balance cannot be split by a race. The listener
/// descriptor is closed only by the accept source's cancel handler (or
/// directly when no source was ever armed), never from the main actor, so
/// the queue-side drain can never `accept(2)` on a recycled descriptor.
@MainActor
public final class SocketControlServer {
    /// The full listener state machine, main-actor isolated. One value,
    /// mirroring the legacy field block.
    struct ListenerState {
        var socketPath: String
        var boundSocketPathIdentity: SocketPathIdentity?
        var serverSocket: Int32 = -1
        var isRunning = false
        var acceptLoopAlive = false
        var activeAcceptLoopGeneration: UInt64 = 0
        var nextAcceptLoopGeneration: UInt64 = 0
        var pendingAcceptLoopRearmGeneration: UInt64?
        var reservedStartupSocketPath: String?
        var reservedStartupSocketPathCanReplaceRefusedSocket = false
        var listenerStartInProgress = false
        var socketPathLockFD: Int32 = -1
        var listenerReadSource: (any DispatchSourceRead)?
        var listenerReadSourceSuspended = false
        var socketPathMonitorSource: (any DispatchSourceFileSystemObject)?
        var accessMode: SocketControlMode = .cmuxOnly
    }

    /// Sendable snapshot of the listener state, published to the read mirror
    /// after every mutation and served by the synchronous read API.
    struct ListenerStateSnapshot: Sendable {
        let socketPath: String
        let boundSocketPathIdentity: SocketPathIdentity?
        let serverSocket: Int32
        let isRunning: Bool
        let acceptLoopAlive: Bool
        let activeGeneration: UInt64
        let pendingRearmGeneration: UInt64?
        let reservedStartupSocketPath: String?
        let listenerStartInProgress: Bool
        let socketPathLockHeld: Bool
        let accessMode: SocketControlMode
    }

    /// The accept path's own state: the consecutive-failure streak (legacy
    /// `acceptSourceConsecutiveFailures`) and a latch that bounds re-fires
    /// while one recovery decision is in flight to the main actor. Keyed by
    /// generation so a stale drain can never pollute a newer listener's
    /// streak.
    struct AcceptRecoveryState: Sendable {
        var generation: UInt64 = 0
        var consecutiveFailures = 0
        var recoveryHopInFlight = false
    }

    /// Authoritative state; mutated only through ``withListenerState(_:)``
    /// so every change publishes to the mirror.
    private var state: ListenerState

    /// Last-published state snapshot for the nonisolated synchronous reads.
    /// Lock carve-out: single writer (the main-actor mutators), short
    /// critical sections over an immutable value; readers are per-client-read
    /// and surface-spawn hot paths that must never wait on other work.
    private nonisolated let stateMirror: OSAllocatedUnfairLock<ListenerStateSnapshot>

    /// Accept-path streak + recovery latch. Lock carve-out: a tiny counter
    /// and flag shared between the queue-side drain (increment/reset) and
    /// the main-actor recovery and start/stop paths (seed/clear).
    nonisolated let acceptRecovery: OSAllocatedUnfairLock<AcceptRecoveryState>

    /// Serial delivery queue for the accept read source and the path-monitor
    /// source. Event delivery only — it protects no state.
    nonisolated let socketListenerQueue = DispatchQueue(label: "com.cmux.socket.listener")

    /// Stateless syscall surface (bind, locks, probes, client config).
    public nonisolated let transport: SocketTransport
    /// Pure recovery/unlink/fallback policy.
    public nonisolated let listenerPolicy: SocketListenerPolicy
    /// Host callbacks; see ``SocketControlServerEvents``.
    nonisolated let events: SocketControlServerEvents
    /// Recovery-delay clock (accept-source resume backoff).
    public nonisolated let recoveryClock: any SocketRecoveryClock

    /// Accepted, configured client connections, in accept order.
    ///
    /// The composition root must run exactly one long-lived consumer over
    /// this stream for the server's lifetime; descriptor ownership transfers
    /// with each yielded ``ControlConnection``. The stream spans listener
    /// restarts and never finishes. Connections buffered but never consumed
    /// keep their descriptors open, so a host without an eternal consumer
    /// leaks descriptors by construction.
    public nonisolated let connections: AsyncStream<ControlConnection>
    nonisolated let connectionsContinuation: AsyncStream<ControlConnection>.Continuation

    /// Pending accept-source resume deadline; cancelled by ``stop()``. At
    /// most one is in flight: the source is suspended while it waits, so no
    /// further accept failures can schedule another.
    var acceptResumeTask: Task<Void, Never>?

    /// Creates a control-socket server.
    /// - Parameters:
    ///   - initialSocketPath: Path reported before any reservation or start;
    ///     defaults to the stable per-variant default. Injectable for tests.
    ///   - transport: Stateless transport; defaults preserve production
    ///     timeouts/backlog.
    ///   - listenerPolicy: Recovery policy; defaults preserve production
    ///     backoff/rearm behavior.
    ///   - recoveryClock: Clock for recovery delays; defaults to the
    ///     continuous clock.
    ///   - events: Host callback seam.
    public init(
        initialSocketPath: String = SocketControlSettings.stableDefaultSocketPath,
        transport: SocketTransport = SocketTransport(),
        listenerPolicy: SocketListenerPolicy = SocketListenerPolicy(),
        recoveryClock: any SocketRecoveryClock = SystemSocketRecoveryClock(),
        events: SocketControlServerEvents
    ) {
        let initialState = ListenerState(socketPath: initialSocketPath)
        self.state = initialState
        self.stateMirror = OSAllocatedUnfairLock(initialState: Self.snapshot(of: initialState))
        self.acceptRecovery = OSAllocatedUnfairLock(initialState: AcceptRecoveryState())
        self.transport = transport
        self.listenerPolicy = listenerPolicy
        self.recoveryClock = recoveryClock
        self.events = events
        (self.connections, self.connectionsContinuation) =
            AsyncStream<ControlConnection>.makeStream()
    }

    /// Runs `body` with exclusive access to the listener state and publishes
    /// the resulting snapshot to the read mirror. The direct successor of the
    /// legacy lock helper; every former critical section maps to one call.
    @discardableResult
    func withListenerState<T>(_ body: (inout ListenerState) -> T) -> T {
        let result = body(&state)
        let snapshot = Self.snapshot(of: state)
        stateMirror.withLock { $0 = snapshot }
        return result
    }

    private static func snapshot(of state: ListenerState) -> ListenerStateSnapshot {
        ListenerStateSnapshot(
            socketPath: state.socketPath,
            boundSocketPathIdentity: state.boundSocketPathIdentity,
            serverSocket: state.serverSocket,
            isRunning: state.isRunning,
            acceptLoopAlive: state.acceptLoopAlive,
            activeGeneration: state.activeAcceptLoopGeneration,
            pendingRearmGeneration: state.pendingAcceptLoopRearmGeneration,
            reservedStartupSocketPath: state.reservedStartupSocketPath,
            listenerStartInProgress: state.listenerStartInProgress,
            socketPathLockHeld: state.socketPathLockFD >= 0,
            accessMode: state.accessMode
        )
    }

    // MARK: - Synchronous reads

    /// Whether the listener is running. Polled by client reader threads
    /// between reads, matching the legacy per-line `isRunning` check.
    public nonisolated var isRunning: Bool {
        listenerStateSnapshot().isRunning
    }

    /// The access mode of the current (or most recently started) listener.
    public nonisolated var accessMode: SocketControlMode {
        listenerStateSnapshot().accessMode
    }

    /// The listener's current socket path, regardless of lifecycle phase.
    public nonisolated var currentSocketPath: String {
        listenerStateSnapshot().socketPath
    }

    /// The active accept-loop generation: a monotonic id stamped on every
    /// listener (re)start and reset to `0` on stop.
    ///
    /// Every restart routes through the same startup that bumps this — the
    /// host-driven start/stop, the path monitor's rearm, and the accept
    /// source's recovery rebind alike — so it is the authoritative signal
    /// that "the listener a caller last observed has since been replaced."
    /// A blocking readiness probe captures this before it runs and re-reads
    /// it afterward; a change means the probed listener is gone and any
    /// rebind decision derived from that probe is stale, so acting on it
    /// would tear down a freshly recovered listener and drop its clients
    /// (https://github.com/manaflow-ai/cmux/issues/6406, activation/wake
    /// race). See ``SocketListenerActivationRecoveryPolicy/rebindDecisionIsCurrent(capturedGeneration:currentGeneration:)``.
    public nonisolated var activeListenerGeneration: UInt64 {
        listenerStateSnapshot().activeGeneration
    }

    /// The socket path remote-session restore should reconnect through, or
    /// `nil` when no listener is active or reserved.
    public nonisolated func currentSocketPathForRemoteRestore() -> String? {
        let snapshot = listenerStateSnapshot()
        if snapshot.isRunning || snapshot.acceptLoopAlive || snapshot.listenerStartInProgress
            || snapshot.serverSocket >= 0 {
            return snapshot.socketPath
        }
        return snapshot.reservedStartupSocketPath
    }

    /// The path the listener is using (when active in any phase), the
    /// reserved startup path, or `preferredPath` when fully inactive.
    /// - Parameter preferredPath: The configured path to fall back to.
    /// - Returns: The effective socket path for clients and diagnostics.
    public nonisolated func activeSocketPath(preferredPath: String) -> String {
        let snapshot = listenerStateSnapshot()
        if snapshot.isRunning
            || snapshot.acceptLoopAlive
            || snapshot.listenerStartInProgress
            || snapshot.pendingRearmGeneration != nil
            || snapshot.socketPathLockHeld
            || snapshot.serverSocket >= 0 {
            return snapshot.socketPath
        }
        if let reservedStartupSocketPath = snapshot.reservedStartupSocketPath {
            return reservedStartupSocketPath
        }
        return preferredPath
    }

    /// Point-in-time listener health against the path the host expects.
    /// - Parameter expectedSocketPath: The path the listener should own.
    /// - Returns: Health flags combining listener state and a filesystem
    ///   identity check of `expectedSocketPath`.
    public nonisolated func listenerHealth(expectedSocketPath: String) -> SocketListenerHealth {
        let snapshot = listenerStateSnapshot()
        let pathMatches = snapshot.socketPath == expectedSocketPath
        let currentIdentity = transport.pathIdentity(at: expectedSocketPath)
        let pathExists = currentIdentity != nil
        let pathOwnedByListener = currentIdentity.map { current in
            pathMatches && (snapshot.boundSocketPathIdentity.map { current == $0 } ?? false)
        } ?? false

        return SocketListenerHealth(
            isRunning: snapshot.isRunning,
            acceptLoopAlive: snapshot.acceptLoopAlive,
            socketPathMatches: pathMatches,
            socketPathExists: pathExists,
            socketPathOwnedByListener: pathOwnedByListener
        )
    }

    nonisolated func listenerStateSnapshot() -> ListenerStateSnapshot {
        stateMirror.withLock { $0 }
    }

    // MARK: - Telemetry helpers

    /// Builds the standard listener-event payload (stage + state snapshot).
    nonisolated func socketListenerEventData(
        stage: String,
        errnoCode: Int32? = nil,
        extra: [String: any Sendable] = [:]
    ) -> [String: any Sendable] {
        let snapshot = listenerStateSnapshot()
        var data: [String: any Sendable] = [
            "stage": stage,
            "path": snapshot.socketPath,
            "isRunning": snapshot.isRunning ? 1 : 0,
            "acceptLoopAlive": snapshot.acceptLoopAlive ? 1 : 0,
            "serverSocket": Int(snapshot.serverSocket),
            "activeGeneration": snapshot.activeGeneration,
        ]
        if let errnoCode {
            data["errno"] = Int(errnoCode)
            data["errnoDescription"] = String(cString: strerror(errnoCode))
        }
        for (key, value) in extra {
            data[key] = value
        }
        return data
    }

    nonisolated func reportSocketListenerFailure(
        message: String,
        stage: String,
        errnoCode: Int32? = nil,
        extra: [String: any Sendable] = [:]
    ) {
        let data = socketListenerEventData(stage: stage, errnoCode: errnoCode, extra: extra)
        events.failure(message, stage, errnoCode, data)
    }
}
