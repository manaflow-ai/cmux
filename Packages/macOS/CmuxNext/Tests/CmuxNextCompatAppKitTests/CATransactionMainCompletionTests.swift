import CmuxNextCompatAppKit
import Foundation
import QuartzCore
import Testing

@Suite struct CATransactionMainCompletionTests {
    /// With no animation the completion runs once the transaction commits (CATransaction.h),
    /// on the main thread.
    @Test(.timeLimit(.minutes(1))) func theCompletionRunsOnMainAfterTheCommit() async {
        let log = CompletionLog()
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

/// What the transaction saw, in order.
private final class CompletionLog {
    var events: [String] = []

    func record(_ event: String) {
        events.append(Thread.isMainThread ? event : event + " off main")
    }
}
