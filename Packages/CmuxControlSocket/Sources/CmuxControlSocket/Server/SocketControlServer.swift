public import CmuxSettings
public import CmuxSocketControl
internal import Foundation
internal import os

/// The cmux control-socket listener: path reservation, bind/listen lifecycle,
/// the accept source with failure backoff/rearm, the socket-path monitor, and
/// the generation-counted recovery state machine, lifted faithfully from
/// `TerminalController`.
///
/// The server owns transport state only. Everything app-shaped — telemetry,
/// client command handling, restart scheduling, notifications — crosses the
/// ``SocketControlServerEvents`` seam.
///
/// ## Why a lock and not an actor
///
/// Every driver of this state machine is synchronous and cannot await:
/// `DispatchSource` event/cancel handlers on the listener queue, per-client
/// reader threads polling ``isRunning``, environment construction for spawned
/// terminal surfaces reading ``activeSocketPath(preferredPath:)``, and app
/// termination, where ``stop()`` must unlink the socket and release the path
/// lock before the process exits. The lock also keeps `DispatchSource`
/// suspend/resume balanced by flipping the suspended flag in the same critical
/// section as the suspend/resume call. This is the documented lock carve-out;
/// the actor conversion arrives when client I/O and command dispatch become
/// async in the control-plane coordinator stage.
public final class SocketControlServer: Sendable {
    /// The full listener state machine. One value, one lock, mirroring the
    /// legacy `nonisolated(unsafe)` field block plus its `NSLock`.
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

    /// Sendable snapshot of the listener state for telemetry and health reads.
    struct ListenerStateSnapshot {
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

    // Lock carve-out (see type docs): the state machine is driven exclusively
    // from non-async contexts; `uncheckedState` because the protected value
    // holds DispatchSource references, which only ever enter or leave the
    // critical sections that also maintain their suspend/cancel invariants.
    private let listenerState: OSAllocatedUnfairLock<ListenerState>

    /// Serial queue for listener event delivery: the accept read source, the
    /// path-monitor source, and the delayed accept-source resume. Event
    /// delivery only — state is guarded by `listenerState`, never this queue.
    let socketListenerQueue = DispatchQueue(label: "com.cmux.socket.listener")

    /// Stateless syscall surface (bind, locks, probes, client config).
    public let transport: SocketTransport
    /// Pure recovery/unlink/fallback policy.
    public let listenerPolicy: SocketListenerPolicy
    /// Host callbacks; see ``SocketControlServerEvents``.
    let events: SocketControlServerEvents

    /// Creates a control-socket server.
    /// - Parameters:
    ///   - initialSocketPath: Path reported before any reservation or start;
    ///     defaults to the stable per-variant default. Injectable for tests.
    ///   - transport: Stateless transport; defaults preserve production
    ///     timeouts/backlog.
    ///   - listenerPolicy: Recovery policy; defaults preserve production
    ///     backoff/rearm behavior.
    ///   - events: Host callback seam.
    public init(
        initialSocketPath: String = SocketControlSettings.stableDefaultSocketPath,
        transport: SocketTransport = SocketTransport(),
        listenerPolicy: SocketListenerPolicy = SocketListenerPolicy(),
        events: SocketControlServerEvents
    ) {
        self.listenerState = OSAllocatedUnfairLock(
            uncheckedState: ListenerState(socketPath: initialSocketPath)
        )
        self.transport = transport
        self.listenerPolicy = listenerPolicy
        self.events = events
    }

    /// Runs `body` with exclusive access to the listener state. The direct
    /// successor of the legacy `withListenerState` `NSLock` helper; critical
    /// sections stay short and non-blocking apart from the few syscalls the
    /// legacy code performed under the same lock.
    @discardableResult
    func withListenerState<T>(_ body: (inout ListenerState) -> T) -> T {
        listenerState.withLockUnchecked { state in
            body(&state)
        }
    }

    // MARK: - Synchronous reads

    /// Whether the listener is running. Polled by client reader threads
    /// between reads, matching the legacy per-line `isRunning` check.
    public var isRunning: Bool {
        withListenerState { $0.isRunning }
    }

    /// The access mode of the current (or most recently started) listener.
    public var accessMode: SocketControlMode {
        withListenerState { $0.accessMode }
    }

    /// The listener's current socket path, regardless of lifecycle phase.
    public var currentSocketPath: String {
        withListenerState { $0.socketPath }
    }

    /// The socket path remote-session restore should reconnect through, or
    /// `nil` when no listener is active or reserved.
    public func currentSocketPathForRemoteRestore() -> String? {
        withListenerState { state in
            if state.isRunning || state.acceptLoopAlive || state.listenerStartInProgress
                || state.serverSocket >= 0 {
                return state.socketPath
            }
            return state.reservedStartupSocketPath
        }
    }

    /// The path the listener is using (when active in any phase), the
    /// reserved startup path, or `preferredPath` when fully inactive.
    /// - Parameter preferredPath: The configured path to fall back to.
    /// - Returns: The effective socket path for clients and diagnostics.
    public func activeSocketPath(preferredPath: String) -> String {
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
    public func listenerHealth(expectedSocketPath: String) -> SocketListenerHealth {
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

    func listenerStateSnapshot() -> ListenerStateSnapshot {
        withListenerState { state in
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
    }

    func shouldContinueAcceptLoop(generation: UInt64) -> Bool {
        withListenerState { state in
            state.isRunning && generation == state.activeAcceptLoopGeneration
        }
    }

    // MARK: - Telemetry helpers

    /// Builds the standard listener-event payload (stage + state snapshot).
    func socketListenerEventData(
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

    func reportSocketListenerFailure(
        message: String,
        stage: String,
        errnoCode: Int32? = nil,
        extra: [String: any Sendable] = [:]
    ) {
        let data = socketListenerEventData(stage: stage, errnoCode: errnoCode, extra: extra)
        events.failure(message, stage, errnoCode, data)
    }
}
