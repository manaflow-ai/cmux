/// The key-down router as `AppServices` installs it. Where the build declares ``Feature/perfLabCanary`` (DEBUG and
/// bench builds) and the feature is on, the perf lab canary's known regression runs first: a 2 ms spin
/// (``PerfLabKeySpin``) before the router (scripts/perf-lab/canary.py, p12-perf-process.md 3.7). It is composed where
/// the router is made, so it cannot miss the router or be dropped by a later reassignment, and every caller of the
/// route gets it (`CmuxApplication.keyDownInterceptor`, and `debug.key` into a window that is not key, which never
/// passes the app's dispatch). The spin runs once per key-down event: a key routed twice (`debug.key` routes it, then
/// sends it through the app) is held 2 ms, not 4. A shipped build gets the router unchanged.
public struct PerfLabCanaryKeyDown {
    /// The launch's feature values, read on each key-down, so wrapping the router never builds them early.
    public let features: () -> FeatureList?

    public init(features: @escaping () -> FeatureList?) {
        self.features = features
    }

    public func wrap<A: AnyObject, B>(_ route: @escaping (A, B) -> Bool) -> (A, B) -> Bool {
        #if DEBUG || CMUX_BENCH_HOOKS
        let features = features
        let held = LastHeld<A>()
        return PerfLabKeySpin(clock: ContinuousClock()).delaying(route, whenEvent: { event in
            guard features()?.isEnabled(.perfLabCanary) == true, held.event !== event else { return false }
            held.event = event
            return true
        })
        #else
        return route
        #endif
    }

    #if DEBUG || CMUX_BENCH_HOOKS
    /// The key-down event the canary last held. Weak, so a new event at a freed event's address is a new key-down.
    private final class LastHeld<A: AnyObject> {
        weak var event: A?
    }
    #endif
}

#if DEBUG || CMUX_BENCH_HOOKS
/// The perf lab canary's regression (``Feature/perfLabCanary``, plans/cmux-next/chrome-parity/p12-perf-process.md
/// 3.7): each key-down holds the main thread for exactly ``duration`` on ``clock`` before key dispatch, as a slow
/// key handler would. `scripts/perf-lab/canary.py` turns the feature on in one commit of a scratch ref and checks
/// that the lab alerts on the step, bisects to that commit and verifies it.
///
/// It busy-waits on purpose: a sleep or a yield would let the run loop do other work, and the lab must see the
/// key-to-frame latency grow by the whole ``duration``. Only DEBUG and bench (`CMUX_BENCH_HOOKS`) builds compile it
/// and the feature; ``PerfLabCanaryKeyDown`` installs it, and a Release build has neither.
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

    /// `dispatch` with ``spin()`` before each call for which `isOn` is true (``PerfLabCanaryKeyDown`` reads
    /// ``Feature/perfLabCanary``).
    public func delaying<A, B, R>(_ dispatch: @escaping (A, B) -> R, when isOn: @escaping () -> Bool) -> (A, B) -> R {
        delaying(dispatch, whenEvent: { _ in isOn() })
    }

    /// `dispatch` with ``spin()`` before each call whose first argument `isOn` accepts (``PerfLabCanaryKeyDown``:
    /// the canary is on and this key-down was not held yet).
    public func delaying<A, B, R>(_ dispatch: @escaping (A, B) -> R, whenEvent isOn: @escaping (A) -> Bool) -> (A, B) -> R {
        { first, second in
            if isOn(first) { spin() }
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
