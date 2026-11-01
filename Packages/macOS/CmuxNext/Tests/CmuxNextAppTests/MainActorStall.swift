import Foundation

/// A main-actor stall: what a parallel run of the whole target does to one test, reproduced in that test.
/// At `SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH=4` or 6 the live-app tests share one main actor, so a test's
/// own main-actor work (a reply's delivery, a poll's wake-up) waits behind theirs: seconds (a 10 s poll ended after
/// 33.6 s once at width 6). A test that reads the wall clock as correctness fails there and passes alone.
///
/// ``schedule()`` queues one main-actor turn that stays busy (CPU work, as other tests' turns are) for `duration`.
@MainActor
struct MainActorStall {
    let duration: Duration

    /// Queues the busy turn after the main-actor work already queued.
    func schedule() -> Task<Void, Never> {
        let duration = duration
        return Task { @MainActor in
            let end = ContinuousClock.now + duration
            while ContinuousClock.now < end {}
        }
    }
}
