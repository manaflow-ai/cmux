import CmuxNextCompatAppKit
import Foundation
import QuartzCore
import Testing

/// What the transaction callbacks saw, in order.
private final class CallbackLog {
    var events: [String] = []

    func record(_ event: String) {
        events.append(Thread.isMainThread ? event : event + " off main")
    }
}

@Suite struct CATransactionMainCompletionTests {
    /// With no animation the completion runs once the transaction commits (CATransaction.h),
    /// on the main thread.
    @Test(.timeLimit(.minutes(1))) func theCompletionRunsOnMainAfterTheCommit() async {
        let log = CallbackLog()
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            CATransaction.begin()
            CATransaction.setMainCompletion {
                log.record("completion")
                done.resume()
            }
            log.record("commit")
            CATransaction.commit()
        }
        #expect(log.events == ["commit", "completion"])
    }
}
