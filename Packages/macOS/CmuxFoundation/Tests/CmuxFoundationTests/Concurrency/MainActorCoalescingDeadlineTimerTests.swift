import Foundation
import Testing
@testable import CmuxFoundation

@Suite(.serialized)
struct MainActorCoalescingDeadlineTimerTests {
    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func cancellationDisarmsTimerAndAllowsSuccessor() async throws {
        let owner = NSObject()
        let actions = AsyncStream<Void>.makeStream()
        defer { actions.continuation.finish() }
        var actionIterator = actions.stream.makeAsyncIterator()
        let timer = MainActorCoalescingDeadlineTimer(owner: owner) { _ in
            actions.continuation.yield()
        }

        timer.schedule(after: .seconds(60))
        #expect(timer.isScheduled)
        timer.cancel()
        #expect(!timer.isScheduled)

        timer.schedule(after: .zero)
        _ = try #require(await actionIterator.next())
        #expect(!timer.isScheduled)
    }

    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func deadOwnerSuppressesActionAtDeadline() async {
        var owner: NSObject? = NSObject()
        weak var weakOwner = owner
        var actionCount = 0
        let timer = MainActorCoalescingDeadlineTimer(owner: owner!) { _ in
            actionCount += 1
        }

        timer.schedule(after: .zero)
        owner = nil
        #expect(weakOwner == nil)

        for _ in 0..<100 {
            guard timer.isScheduled else { break }
            await Task.yield()
        }

        #expect(!timer.isScheduled)
        #expect(actionCount == 0)
    }
}
