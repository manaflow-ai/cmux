public import CmuxSettings
public import CmuxSocketControl
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
/// ## Isolation design: an actor on the listener queue
///
/// The server is an actor whose serial executor **is** the listener
/// `DispatchSerialQueue`. That one choice resolves every synchronous driver
/// that previously forced the lock-based core:
///
/// - The accept and path-monitor `DispatchSource` handlers already run on the
///   listener queue, so they enter actor isolation synchronously via
///   `assumeIsolated` — no task hop, no event reordering.
/// - Hosts with synchronous contracts (app-termination teardown, startup path
///   reservation, main-thread restarts) bridge through ``performSync(_:)``,
///   which runs an isolated closure via `queue.sync`. The graceful-quit
///   unlink still completes before the process exits.
/// - Hot-path synchronous reads (``isRunning`` polled per client read,
///   ``activeSocketPath(preferredPath:)`` on the surface-spawn path) never
///   touch the queue: every isolated mutation publishes a snapshot to a
///   lock-guarded mirror, and the read API serves from that mirror at the
///   same cost as the previous lock.
///
/// All mutable listener state — including the `DispatchSource` references and
/// their suspend/cancel invariants — is actor-isolated; the manual lock state
/// machine is gone.
public actor SocketControlServer {
    /// The full listener state machine, actor-isolated. One value, mirroring
    /// the legacy field block.
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
        var acceptSourceConsecutiveFailures = 0
        var accessMode: SocketControlMode = .cmuxOnly
    }

    /// Sendable snapshot of the listener state, published to the read mirror
    /// after every isolated mutation and served by the synchronous read API.
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

    /// Authoritative state; actor-isolated, mutated only through
    /// ``withListenerState(_:)`` so every change publishes to the mirror.
    private var state: ListenerState

    /// Last-published state snapshot for the nonisolated synchronous reads.
    /// Single writer (the actor); readers pay one unfair-lock acquire, exactly
    /// the cost profile of the previous lock-based core.
    private nonisolated let stateMirror: OSAllocatedUnfairLock<ListenerStateSnapshot>

    /// The serial queue that is this actor's executor. Also the delivery
    /// queue for the accept read source and the path-monitor source, whose
    /// handlers enter isolation synchronously via `assumeIsolated`.
    nonisolated let socketListenerQueue: DispatchSerialQueue

    public nonisolated var unownedExecutor: UnownedSerialExecutor {
        socketListenerQueue.asUnownedSerialExecutor()
    }

    /// Stateless syscall surface (bind, locks, probes, client config).
    public nonisolated let transport: SocketTransport
    /// Pure recovery/unlink/fallback policy.
    public nonisolated let listenerPolicy: SocketListenerPolicy
    /// Host callbacks; see ``SocketControlServerEvents``.
    nonisolated let events: SocketControlServerEvents
    /// Recovery-delay clock (accept-source resume backoff).
    nonisolated let recoveryClock: any SocketRecoveryClock

    /// Accepted, configured client connections, in accept order.
    ///
    /// The composition root must run exactly one long-lived consumer over
    /// this stream; descriptor ownership transfers with each yielded
    /// ``ControlConnection``. The stream spans listener restarts and never
    /// finishes for the server's lifetime.
    public nonisolated let connections: AsyncStream<ControlConnection>
    nonisolated let connectionsContinuation: AsyncStream<ControlConnection>.Continuation

    /// Pending accept-source resume deadline; cancelled by ``stop()``. At most
    /// one is in flight because a suspended source cannot produce the accept
    /// failures that schedule another.
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
        self.socketListenerQueue = DispatchSerialQueue(label: "com.cmux.socket.listener")
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

    // MARK: - Synchronous bridge

    /// Synchronously runs `body` isolated on the server's executor.
    ///
    /// The bridge for the host's synchronous contracts: app-termination
    /// teardown (the socket unlink and path-lock release must complete before
    /// the process exits), startup path reservation (terminal surfaces spawn
    /// with the reserved path in their environment in the same main-thread
    /// turn), and main-thread stop/start restarts. The closure runs after any
    /// in-flight listener-queue work drains; it must not be called from the
    /// listener queue itself (enforced by precondition).
    /// - Parameter body: Isolated work; runs synchronously on the executor.
    /// - Returns: The closure's value.
    public nonisolated func performSync<T: Sendable>(
        _ body: @Sendable (isolated SocketControlServer) throws -> T
    ) rethrows -> T {
        dispatchPrecondition(condition: .notOnQueue(socketListenerQueue))
        return try socketListenerQueue.sync {
            try assumeIsolated { isolatedServer in
                try body(isolatedServer)
            }
        }
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

    func shouldContinueAcceptLoop(generation: UInt64) -> Bool {
        state.isRunning && generation == state.activeAcceptLoopGeneration
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
