import Foundation
import Testing
@testable import CmuxMobileModel

/// Review m4: sign-out waits for the Mac's unpair at most 3 s, also when
/// the unpair is stuck in a wait that ignores cancellation.
@Suite struct BoundedWaitTests {
    /// A wait that never ends and ignores cancellation.
    final class Stuck: @unchecked Sendable {
        let lock = NSLock()
        var held: CheckedContinuation<Void, Never>?
        func wait() async { await withCheckedContinuation { c in lock.withLock { held = c } } }
        func release() { lock.withLock { held }?.resume() }
    }

    @Test func returnsAtTheLimitWhenTheWorkIgnoresCancellation() async {
        let stuck = Stuck()
        let started = ContinuousClock.now
        let finished = await BoundedWait(.milliseconds(100)).run { await stuck.wait() }
        let elapsed = ContinuousClock.now - started
        #expect(!finished)
        #expect(elapsed < .seconds(2))
        stuck.release()
    }

    @Test func returnsAsSoonAsTheWorkEnds() async {
        let finished = await BoundedWait(.seconds(30)).run {}
        #expect(finished)
    }
}
