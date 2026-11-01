import Foundation

/// A main-actor stall on request: what a parallel run of the whole target does to one test, reproduced in that test.
/// At `SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH=4` or 6 the live-app tests share one main actor, so a test's
/// own main-actor work (a reply's delivery, a poll's wake-up) waits behind theirs: seconds, and once 23 s in the
/// width-6 run. A test that reads the wall clock as correctness fails there and passes alone.
///
/// `CMUX_TEST_MAIN_ACTOR_STALL_SECONDS=N` makes ``schedule()`` queue one main-actor turn that stays busy (CPU work,
/// as other tests' turns are) for N seconds. Unset, it does nothing, so a normal run never slows the tests around it.
@MainActor
struct MainActorStall {
    static let variable = "CMUX_TEST_MAIN_ACTOR_STALL_SECONDS"

    let duration: Duration?

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        duration = environment[Self.variable].flatMap(Double.init).flatMap { $0 > 0 ? .milliseconds(Int($0 * 1000)) : nil }
    }

    /// Queues the busy turn after the main-actor work already queued; nil when no stall is asked for.
    @discardableResult
    func schedule() -> Task<Void, Never>? {
        guard let duration else { return nil }
        return Task { @MainActor in
            let end = ContinuousClock.now + duration
            while ContinuousClock.now < end {}
        }
    }
}
