import AppKit
import CmuxNextFeatures

/// The key-down router as `AppServices` installs it. In a bench build (`CMUX_BENCH_HOOKS`) with
/// ``Feature/perfLabCanary`` on, the perf lab canary's known regression runs first: a 2 ms spin
/// (``PerfLabKeySpin``) before the key router (scripts/perf-lab/canary.py, p12-perf-process.md 3.7). The spin is
/// composed where the router is made, so it cannot miss the router or come after a later reassignment. Any other
/// build gets the router unchanged.
@MainActor
struct PerfLabCanaryKeyDown {
    /// The launch's feature values, read on each key-down, so wrapping the router never builds them early.
    let features: () -> FeatureList?

    func wrap(_ route: @escaping (NSEvent, NSWindow?) -> Bool) -> (NSEvent, NSWindow?) -> Bool {
        #if CMUX_BENCH_HOOKS
        let features = features
        return PerfLabKeySpin(clock: ContinuousClock()).delaying(route, when: {
            features()?.isEnabled(.perfLabCanary) == true
        })
        #else
        return route
        #endif
    }
}
