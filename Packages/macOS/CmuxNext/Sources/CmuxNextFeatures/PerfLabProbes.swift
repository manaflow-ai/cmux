#if DEBUG || CMUX_BENCH_HOOKS
/// The perf lab canary's regression (``Feature/perfLabCanary``, plans/cmux-next/chrome-parity/p12-perf-process.md
/// 3.7): each key-down holds the main thread for exactly ``duration`` on ``clock`` before key dispatch, as a slow
/// key handler would. `scripts/perf-lab/canary.py` turns the feature on in one commit of a scratch ref and checks
/// that the lab alerts on the step, bisects to that commit and verifies it.
///
/// It busy-waits on purpose: a sleep or a yield would let the run loop do other work, and the lab must see the
/// key-to-frame latency grow by the whole ``duration``. DEBUG compiles it for its tests; only a bench build
/// (`CMUX_BENCH_HOOKS`) installs it (`AppProcessRoot.adopt`), and a Release build has neither.
public struct PerfLabKeySpin<C: Clock>: Sendable where C.Duration == Duration {
    public let clock: C
    public let duration: Duration

    /// `duration` defaults to the canary's step on every key-to-frame series.
    public init(clock: C, duration: Duration = .milliseconds(2)) {
        self.clock = clock
        self.duration = duration
    }

    /// Returns at the first reading of ``clock`` at or past ``duration`` from the call, and returns that reading.
    @discardableResult
    public func spin() -> C.Instant {
        let deadline = clock.now.advanced(by: duration)
        var now = clock.now
        while now < deadline { now = clock.now }
        return now
    }

    /// `dispatch` with ``spin()`` before each call: the key-down dispatcher a bench build with the canary on runs.
    public func delaying<A, B, R>(_ dispatch: @escaping (A, B) -> R) -> (A, B) -> R {
        { first, second in
            spin()
            return dispatch(first, second)
        }
    }
}

/// What a bench build reports about the perf lab features at launch (``Feature/perfLabKillProbe``, done check
/// 13): the kill probe changes nothing, so its value and source are the whole proof that a signed flags document
/// reached the app's ``FeatureList``.
public struct PerfLabFeatureReport: Sendable, Equatable {
    public let canary: Feature.Resolution
    public let killProbe: Feature.Resolution

    public init(_ features: FeatureList) {
        canary = features.resolution(of: .perfLabCanary)
        killProbe = features.resolution(of: .perfLabKillProbe)
    }

    /// `perf lab: perfLabCanary=off source=default perfLabKillProbe=off source=remote`.
    public var line: String {
        "perf lab: \(Feature.perfLabCanary.name)=\(canary) \(Feature.perfLabKillProbe.name)=\(killProbe)"
    }
}
#endif
