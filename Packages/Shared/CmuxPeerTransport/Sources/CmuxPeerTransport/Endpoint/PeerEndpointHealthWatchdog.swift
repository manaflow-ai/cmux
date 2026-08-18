/// Liveness verdict produced by an endpoint health probe.
public enum PeerEndpointHealthVerdict: Sendable, Equatable {
    /// Intentionally not active (deactivated, backgrounded). Never triggers
    /// a recreate.
    case inactive
    /// The endpoint is live and bound.
    case healthy
    /// Terminal driver death (upstream iroh#4289: failed socket rebind kills
    /// the endpoint driver). The payload is the human-readable reason.
    case dead(String)
}

/// Periodically probes endpoint liveness and calls a recreate closure on
/// terminal failure. This is the mitigation for upstream iroh#4289 kept at
/// our layer: recreate from the same secret key, advancing only the runtime
/// generation.
///
/// The loop is a single cancellable task on an injected `Clock`; the check
/// interval bounds both probe frequency and recreate frequency (at most one
/// recreate per tick). There are no detached sleeps used as synchronization.
public actor PeerEndpointHealthWatchdog<WatchClock: Clock>
where WatchClock.Duration == Duration {
    public typealias Probe = @Sendable () async -> PeerEndpointHealthVerdict
    public typealias RecreateHandler = @Sendable (_ reason: String) async -> Void

    private let clock: WatchClock
    private let checkInterval: Duration
    private let probe: Probe
    private let recreate: RecreateHandler
    private var loopTask: Task<Void, Never>?

    /// - Parameters:
    ///   - interval: Time between probes; must be positive. Also the floor
    ///     between consecutive recreates.
    ///   - clock: Injected clock driving the probe cadence.
    ///   - probe: Lightweight liveness check, typically
    ///     `PeerEndpointManager.probeHealth()`.
    ///   - recreate: Invoked with the failure reason on every `.dead` verdict,
    ///     typically `PeerEndpointManager.recreate()`.
    public init(
        interval: Duration,
        clock: WatchClock,
        probe: @escaping Probe,
        recreate: @escaping RecreateHandler
    ) {
        precondition(interval > .zero, "watchdog interval must be positive")
        self.clock = clock
        self.checkInterval = interval
        self.probe = probe
        self.recreate = recreate
    }

    deinit {
        loopTask?.cancel()
    }

    public var isRunning: Bool { loopTask != nil }

    /// Starts the probe loop. Idempotent while running.
    public func start() {
        guard loopTask == nil else { return }
        loopTask = Task { [clock, checkInterval, probe, recreate] in
            while !Task.isCancelled {
                do {
                    try await clock.sleep(
                        until: clock.now.advanced(by: checkInterval),
                        tolerance: nil
                    )
                } catch {
                    return // Cancelled; nothing else throws here.
                }
                guard !Task.isCancelled else { return }
                if case .dead(let reason) = await probe() {
                    await recreate(reason)
                }
            }
        }
    }

    /// Stops the probe loop. A probe or recreate already in flight finishes;
    /// no further ticks run.
    public func stop() {
        loopTask?.cancel()
        loopTask = nil
    }
}

extension PeerEndpointHealthWatchdog where WatchClock == ContinuousClock {
    /// Convenience for production use on the continuous clock.
    public init(
        interval: Duration,
        probe: @escaping Probe,
        recreate: @escaping RecreateHandler
    ) {
        self.init(
            interval: interval,
            clock: ContinuousClock(),
            probe: probe,
            recreate: recreate
        )
    }
}
