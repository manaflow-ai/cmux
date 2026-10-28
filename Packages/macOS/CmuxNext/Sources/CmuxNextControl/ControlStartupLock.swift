import CmuxNextCompat
import CmuxNextSettings
import class CmuxSafeConcurrency.OnceContinuation
import enum CmuxSafeConcurrency.OnceContinuationError
import func CmuxSafeConcurrency.withOnceContinuation
import Foundation

/// The control socket's startup lock (p08-startup-107): Chrome's `ProcessSingletonStartupLock`
/// (chrome/browser/process_singleton_startup_lock.cc), which queues the command lines that reach the
/// process singleton before the browser is ready and replays them in order at `Unlock()`.
///
/// The server accepts as soon as the launch bound the socket (``ControlSocketBind``), checks each peer and
/// parses each request on the connection's own queue and task, then asks this lock before it routes
/// (``admit()``). Until ``unlock(router:)`` hands over the router with every method group registered, a
/// request waits here. At most ``capacity`` wait; one more is answered ``startingError(waiting:limit:)``
/// at once: it never ran, and its `retry_after_ms` says when to send it again. At unlock the waiting
/// requests are dispatched in the order they arrived, as Chrome's `Unlock()` runs its queued callbacks in
/// order: each holds a ``Turn`` until the router dispatched it (its main-actor work item is queued, or its
/// call started), not until it is answered, so a slow request never holds the ones behind it. A request
/// that arrives during the replay queues behind it; once the queue is dispatched the lock is open and
/// requests go straight to the router. A server stopped before the unlock stops its lock for good
/// (``refuseWaiting()``): every request, waiting or later, is answered `starting` and none runs.
///
/// ```swift
/// let server = ControlSocketServer(configuration: configuration, startup: ControlStartupLock(), hangs: hangs)
/// try server.start(adopting: listener)  // accepts now; requests wait here
/// // after the last method group registered:
/// server.unlock(router: router)         // dispatches the waiting requests in order
/// ```
public final class ControlStartupLock: Sendable {
    /// Requests that may wait for the unlock (plans/cmux-next/chrome-parity/p08-startup.md, task 107).
    public static let defaultCapacity = 256
    /// When a refused client should send its request again.
    static let retryAfter: Duration = .milliseconds(100)

    /// What a request may do (``admit()``).
    enum Admission: Sendable {
        /// Route it on the router. A replayed request has a turn: the next waiting request is dispatched
        /// once the turn is finished (``Turn/finish()``, or when the turn is released).
        case route(ControlRouter, Turn?)
        /// Answer the error; the request never ran.
        case refused(ControlError)
    }

    /// One replayed request's turn.
    final class Turn: Sendable {
        private let lock: ControlStartupLock
        private let isFinished = Mutex(false)

        fileprivate init(lock: ControlStartupLock) {
            self.lock = lock
        }

        deinit {
            finish()
        }

        /// The router dispatched the request (or it was answered): the next waiting request may be
        /// dispatched. Only the first call counts.
        func finish() {
            let first = isFinished.withLock { finished in
                defer { finished = true }
                return !finished
            }
            if first { lock.turnFinished() }
        }
    }

    private typealias Waiter = OnceContinuation<Admission, OnceContinuationError>

    private enum Phase {
        /// No router yet: requests wait.
        case locked
        /// Unlocked: the waiting requests are dispatched one at a time, and new ones queue behind them.
        case replaying(ControlRouter)
        /// The queue drained: requests route at once.
        case open(ControlRouter)
        /// The server stopped before the unlock: every request is refused, and the unlock changes nothing.
        case stopped
    }

    private struct State {
        var phase = Phase.locked
        /// Waiting requests, oldest first (a slice: a dequeue is O(1); its storage is let go once empty).
        var waiting: ArraySlice<Waiter> = []
        /// A replayed request has its turn: the router has not dispatched it yet.
        var isTurnOut = false

        var waitingCount: Int { waiting.count }

        mutating func dequeue() -> Waiter? {
            let next = waiting.popFirst()
            if waiting.isEmpty { waiting = [] }
            return next
        }
    }

    /// Requests that may wait for the unlock; one more is refused.
    public let capacity: Int
    private let state = Mutex(State())
    /// Called, outside the lock, with the waiting count each time a request starts to wait (tests).
    private let queued: (@Sendable (Int) -> Void)?
    /// Called, outside the lock, with the error each time a request is refused (tests).
    private let refused: (@Sendable (ControlError) -> Void)?

    /// A locked startup lock: requests wait until ``unlock(router:)``.
    ///
    /// - Parameters:
    ///   - queued: Called with the waiting count each time a request starts to wait; nil (the default)
    ///     calls nothing.
    ///   - refused: Called with the error each time a request is refused (a full queue, a stop); nil (the
    ///     default) calls nothing.
    public init(capacity: Int = ControlStartupLock.defaultCapacity, queued: (@Sendable (Int) -> Void)? = nil,
                refused: (@Sendable (ControlError) -> Void)? = nil) {
        self.capacity = max(0, capacity)
        self.queued = queued
        self.refused = refused
    }

    /// An open lock on `router`: a server whose methods are all registered before it accepts.
    public init(unlockedWith router: ControlRouter) {
        capacity = 0
        queued = nil
        refused = nil
        state.withLock { $0.phase = .open(router) }
    }

    /// The router, once unlocked.
    public var router: ControlRouter? {
        state.withLock { state in
            switch state.phase {
            case .locked, .stopped: nil
            case .replaying(let router), .open(let router): router
            }
        }
    }

    /// Whether ``unlock(router:)`` ran (or the lock was made open).
    public var isUnlocked: Bool { router != nil }

    /// Requests waiting for their turn (tests, diagnostics).
    var waitingCount: Int { state.withLock { $0.waitingCount } }

    /// Hands over the router once every method group is registered and replays the waiting requests in
    /// the order they arrived. A second call, or a call after a stop (``refuseWaiting()``), changes nothing.
    public func unlock(router: ControlRouter) {
        let next: (Waiter, Admission)? = state.withLock { state in
            guard case .locked = state.phase else { return nil }
            state.phase = .replaying(router)
            return Self.advance(&state, lock: self)
        }
        if let next { next.0.resume(returning: next.1) }
    }

    /// Whether this request may be routed now, or after its turn in the startup queue. Never blocks a
    /// thread: a request waits by suspending its connection's task.
    func admit() async -> Admission {
        if let router = openRouter { return .route(router, nil) }
        do {
            return try await withOnceContinuation { (waiter: Waiter) in enqueue(waiter) }
        } catch {
            // Only a waiter dropped unresumed ends here, and the queue holds every waiter until it resumes.
            let error = Self.startingError(waiting: waitingCount, limit: capacity)
            refused?(error)
            return .refused(error)
        }
    }

    /// Answers every waiting request `starting` (the server stopped: its connections close). A lock that
    /// was not unlocked yet stops for good: a request that comes later (a line the connection had
    /// buffered, a task between its parse and ``admit()``) is refused at once, and ``unlock(router:)``
    /// changes nothing. A replay in progress, or an open lock (a restart), goes on with later requests.
    func refuseWaiting() {
        let waiting: [Waiter] = state.withLock { state in
            if case .locked = state.phase { state.phase = .stopped }
            let waiting = Array(state.waiting)
            state.waiting = []
            return waiting
        }
        guard !waiting.isEmpty else { return }
        let error = Self.startingError(waiting: waiting.count, limit: capacity)
        for waiter in waiting {
            refused?(error)
            waiter.resume(returning: .refused(error))
        }
    }

    /// `starting`: cmux is still starting and the startup queue is full, or the server stopped before
    /// it unlocked. The request did not run (`not_run`); send it again after `retry_after_ms`.
    static func startingError(waiting: Int, limit: Int) -> ControlError {
        ControlError(code: "starting",
                     message: ControlStrings.format("control.error.starting",
                                                    "cmux is still starting (%1$lld requests waiting, limit %2$lld); retry shortly",
                                                    waiting, limit),
                     data: ["not_run": true, "waiting": JSONValue(waiting), "limit": JSONValue(limit),
                            "retry_after_ms": JSONValue(retryAfter.wholeMilliseconds)])
    }

    // MARK: - Queue

    private var openRouter: ControlRouter? {
        state.withLock { state in
            guard case .open(let router) = state.phase else { return nil }
            return router
        }
    }

    private func enqueue(_ waiter: Waiter) {
        let (now, waiting): (Admission?, Int) = state.withLock { state in
            switch state.phase {
            case .open(let router): return (.route(router, nil), 0)
            case .stopped: return (.refused(Self.startingError(waiting: 0, limit: capacity)), 0)
            case .locked, .replaying: break
            }
            guard state.waitingCount < capacity else {
                return (.refused(Self.startingError(waiting: state.waitingCount, limit: capacity)), state.waitingCount)
            }
            // Locked, or replaying with a turn out (a replay with none out has opened): it waits its turn.
            state.waiting.append(waiter)
            return (nil, state.waitingCount)
        }
        guard let now else {
            queued?(waiting)
            return
        }
        if case .refused(let error) = now { refused?(error) }
        waiter.resume(returning: now)
    }

    fileprivate func turnFinished() {
        let next: (Waiter, Admission)? = state.withLock { state in
            state.isTurnOut = false
            return Self.advance(&state, lock: self)
        }
        if let next { next.0.resume(returning: next.1) }
    }

    /// While replaying with no turn out: the oldest waiting request and its turn, or, with none waiting,
    /// the lock opens. The caller resumes the waiter after the lock is released.
    private static func advance(_ state: inout State, lock: ControlStartupLock) -> (Waiter, Admission)? {
        guard case .replaying(let router) = state.phase, !state.isTurnOut else { return nil }
        guard let next = state.dequeue() else {
            state.phase = .open(router)
            return nil
        }
        state.isTurnOut = true
        return (next, .route(router, Turn(lock: lock)))
    }
}
