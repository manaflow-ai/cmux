import CmuxNextCompat

/// A socket owner's reading of the Mac's sleep and wake in the ``EnergyPolicy``:
/// its keepalive holds while its ``Hold`` says so (the Mac sleeps, or also its displays), and
/// each new ``EnergyPolicy/networkResumes`` (a wake that found a satisfied network path) closes the
/// open connection once when it was open through the sleep, so the owner's retry loop reconnects
/// after a random wait of at most ``EnergyPolicy/reconnectJitter`` instead of its backoff. A
/// connection that another probe already replaced after the wake stays open: one reconnect per
/// socket and wake.
///
/// Chrome splits the same job between its GCM heartbeat, which stops on `OnSuspend` and checks the
/// connection on `OnResume` (google_apis/gcm/engine/heartbeat_manager.cc), and its connection
/// factory, which reconnects once the network is back (google_apis/gcm/engine/connection_factory_impl.cc,
/// `OnNetworkChanged`). A connection that slept is a dead TCP stream the OS has not reported yet, so
/// here the owner reconnects at once instead of waiting for a heartbeat to miss.
///
/// The owner calls ``follow(_:)`` once, ``opened(close:resume:)`` and ``closed()`` around each
/// connection, arms its keepalive inside ``whileAwake(_:)``, and spaces its attempts with
/// ``retryWait(_:timer:)``. A gate with no source never pauses and never reconnects.
public final class KeepaliveGate: Sendable {
    /// When the keepalive holds.
    public enum Hold: Sendable, Equatable {
        /// Only while the Mac sleeps (``EnergyPolicy/suspended``), as Chrome's GCM heartbeat stops on
        /// `OnSuspend` alone. For a socket that must stay reachable while the displays sleep, such as
        /// the device hub socket of a Mac a phone reaches through Mac Screen.
        case systemSleep
        /// While the Mac or its displays sleep (``EnergyPolicy/pausesKeepalives``): nothing on this
        /// Mac can see what the socket brings in.
        case systemOrDisplaySleep

        /// The keepalive holds under `policy`.
        public func holds(_ policy: EnergyPolicy) -> Bool {
            switch self {
            case .systemSleep: policy.suspended
            case .systemOrDisplaySleep: policy.pausesKeepalives
            }
        }
    }

    /// What changed for the owner, in the order the owner gets them for one policy change.
    public enum Edge: Sendable, Equatable {
        /// The keepalive starts to hold (``Hold``): drop the armed keepalive.
        case pause
        /// The keepalive no longer holds: the open connection's `resume` has armed its keepalive again.
        case resume
        /// A wake found the network: the gate closed the open connection if it slept, and the next
        /// ``retryWait(_:timer:)`` waits ``reconnectDelay()``.
        case reconnect
    }

    private enum WaitEnd: Sendable {
        case elapsed
        case reconnect
        case cancelled
    }

    /// The open connection's two hooks, and whether the Mac slept while it was open.
    private struct Connection: Sendable {
        let close: @Sendable () -> Void
        let resume: (@Sendable () -> Void)?
        var slept: Bool
    }

    private struct State {
        var paused: Bool
        var suspended: Bool
        var resumes: UInt64
        /// A reconnect came while nothing waited: the next ``retryWait(_:timer:)`` takes the short wait.
        var pending = false
        /// Nil while no connection is open.
        var connection: Connection?
        /// The retry wait in progress, which a reconnect ends early.
        var wait: FirstOutcome<WaitEnd>?
        var observation: EnergyPolicyObservation?
    }

    private let source: EnergyPolicySource?
    private let hold: Hold
    private let random: @Sendable () -> Double
    // concurrency-allow: the pause flag and the open connection's hooks, read synchronously by the owner's keepalive arm and set by the policy's writer (lock carve-out: a few fields, no I/O; the hooks run after the lock is released).
    private let state: Mutex<State>

    /// A gate on `source`'s policy now; nil never pauses and never reconnects.
    ///
    /// - Parameters:
    ///   - source: The app's one policy source (`MainWorkScheduler.energy`).
    ///   - hold: When the keepalive holds; by default while the Mac or its displays sleep.
    ///   - random: A value in 0..<1 that spreads the reconnect over ``EnergyPolicy/reconnectJitter`` (tests pass a constant).
    public init(_ source: EnergyPolicySource?, hold: Hold = .systemOrDisplaySleep,
                random: @escaping @Sendable () -> Double = { Double.random(in: 0..<1) }) {
        self.source = source
        self.hold = hold
        self.random = random
        let policy = source?.policy ?? .normal
        state = Mutex(State(paused: hold.holds(policy), suspended: policy.suspended, resumes: policy.networkResumes))
    }

    /// The keepalive holds now.
    public var isPaused: Bool { state.withLock { $0.paused } }

    /// Calls `handler` with each edge from now on, on the policy writer's thread, until ``stop()``;
    /// a later call replaces the handler. The pause state restarts from the policy now.
    public func follow(_ handler: @escaping @Sendable (Edge) -> Void) {
        guard let source else { return }
        let observation = source.observe { [weak self] policy in self?.changed(to: policy, handler) }
        let policy = source.policy
        let old = state.withLock { state -> EnergyPolicyObservation? in
            state.paused = hold.holds(policy)
            state.suspended = policy.suspended
            state.resumes = policy.networkResumes
            defer { state.observation = observation }
            return state.observation
        }
        old?.cancel()
    }

    /// Stops the edges; a pending reconnect is dropped.
    public func stop() {
        let old = state.withLock { state -> EnergyPolicyObservation? in
            state.pending = false
            defer { state.observation = nil }
            return state.observation
        }
        old?.cancel()
    }

    /// Runs `arm` now unless the keepalive holds, under the lock a ``Edge/pause`` is decided under, so
    /// a keepalive armed by a frame that races the pause is still dropped by the owner's pause handler.
    /// `arm` must only schedule (a `DemandTimer`), never wait.
    public func whileAwake(_ arm: () -> Void) {
        state.withLock { state in
            guard !state.paused else { return }
            arm()
        }
    }

    /// A connection opened: a reconnect closes it with `close`, and a ``Edge/resume`` calls `resume`
    /// (which arms its keepalive) unless the same change reconnects. A reconnect that came while it
    /// was being opened is served by this connection.
    public func opened(close: @escaping @Sendable () -> Void, resume: (@Sendable () -> Void)? = nil) {
        state.withLock { state in
            state.connection = Connection(close: close, resume: resume, slept: state.suspended)
            state.pending = false
        }
    }

    /// The open connection closed.
    public func closed() {
        state.withLock { $0.connection = nil }
    }

    /// The random wait of one reconnect after a wake: 0 up to ``EnergyPolicy/reconnectJitter``.
    public func reconnectDelay() -> Duration {
        .seconds(EnergyPolicy.reconnectJitter.inSeconds * min(max(random(), 0), 1))
    }

    /// Waits before the owner's next attempt: `backoff`'s next step on `timer`, or ``reconnectDelay()``
    /// with `backoff` reset when a reconnect came before or during the wait.
    ///
    /// - Throws: `CancellationError` when the calling task is cancelled.
    public func retryWait(_ backoff: inout Backoff, timer: DemandTimer) async throws {
        var reconnect = false
        while true {
            let delay: Duration
            if reconnect {
                backoff.reset()
                delay = reconnectDelay()
            } else {
                delay = backoff.next()
            }
            switch await waitStep(delay, timer: timer) {
            case .elapsed: return
            case .cancelled: throw CancellationError()
            case .reconnect: reconnect = true
            }
        }
    }

    /// Sleeps `delay` on `timer` with Backoff's tolerance, unless a reconnect (one that came before it
    /// too) or cancellation ends it.
    private func waitStep(_ delay: Duration, timer: DemandTimer) async -> WaitEnd {
        let outcome = FirstOutcome<WaitEnd>()
        let pending = state.withLock { state -> Bool in
            guard !state.pending else {
                state.pending = false
                return true
            }
            state.wait = outcome
            return false
        }
        if pending { return .reconnect }
        timer.schedule(after: delay, tolerance: Backoff.tolerance(for: delay)) { outcome.resolve(.elapsed) }
        let end = await withTaskCancellationHandler {
            await outcome.value()
        } onCancel: {
            outcome.resolve(.cancelled)
        }
        // Still this wait's (a cancel): drop its deadline. A reconnect took the wait already, and the
        // next sleep's schedule replaces the deadline, so a later wait's timer is never touched.
        let current = state.withLock { state -> Bool in
            guard state.wait === outcome else { return false }
            state.wait = nil
            return true
        }
        if current { timer.cancel() }
        return end
    }

    /// Turns a policy change into the owner's edges: on a new resume it closes the open connection
    /// that slept or ends the retry wait; on a resume alone it calls the open connection's `resume`.
    private func changed(to policy: EnergyPolicy, _ handler: @Sendable (Edge) -> Void) {
        let (edges, hook, wait) = state.withLock { state -> ([Edge], (@Sendable () -> Void)?, FirstOutcome<WaitEnd>?) in
            var edges: [Edge] = []
            state.suspended = policy.suspended
            if policy.suspended { state.connection?.slept = true }
            if hold.holds(policy) != state.paused {
                state.paused = hold.holds(policy)
                edges.append(state.paused ? .pause : .resume)
            }
            guard policy.networkResumes > state.resumes else {
                return (edges, edges == [.resume] ? state.connection?.resume : nil, nil)
            }
            state.resumes = policy.networkResumes
            edges.append(.reconnect)
            let wait = state.wait
            state.wait = nil
            // A wait in progress ends early; otherwise the next one is short, unless a connection
            // opened since the wake (another probe replaced the one that slept) serves it.
            let open = state.connection
            state.pending = wait == nil && open?.slept != false
            return (edges, open?.slept == true ? open?.close : nil, wait)
        }
        hook?()
        wait?.resolve(.reconnect)
        for edge in edges { handler(edge) }
    }
}
