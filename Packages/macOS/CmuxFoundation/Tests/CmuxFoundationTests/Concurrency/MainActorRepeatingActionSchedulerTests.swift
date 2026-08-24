import Foundation
import Testing

@testable import CmuxFoundation

@Suite(.serialized)
struct MainActorRepeatingActionSchedulerTests {
    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func repeatsUntilCancelled() async throws {
        let actions = AsyncStream<Int>.makeStream()
        defer { actions.continuation.finish() }
        var actionIterator = actions.stream.makeAsyncIterator()
        let scheduler = MainActorRepeatingActionScheduler()
        var actionCount = 0

        scheduler.startIfIdle(every: .zero) {
            actionCount += 1
            actions.continuation.yield(actionCount)
            if actionCount == 3 {
                scheduler.cancel()
            }
        }

        let firstAction = try #require(await actionIterator.next())
        let secondAction = try #require(await actionIterator.next())
        let thirdAction = try #require(await actionIterator.next())
        #expect(firstAction == 1)
        #expect(secondAction == 2)
        #expect(thirdAction == 3)
        #expect(!scheduler.isRunning)
    }

    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func runningActionIsNotReplaced() async throws {
        let actions = AsyncStream<Int>.makeStream()
        defer { actions.continuation.finish() }
        var actionIterator = actions.stream.makeAsyncIterator()
        let scheduler = MainActorRepeatingActionScheduler()

        scheduler.startIfIdle(every: .seconds(60)) {
            actions.continuation.yield(1)
            scheduler.cancel()
        }
        scheduler.startIfIdle(every: .zero) {
            actions.continuation.yield(2)
            scheduler.cancel()
        }

        let firstAction = try #require(await actionIterator.next())
        #expect(firstAction == 1)
        #expect(!scheduler.isRunning)
    }

    @Test
    @MainActor
    func cancellationReleasesCapturedAction() {
        let scheduler = MainActorRepeatingActionScheduler()
        var owner: NSObject? = NSObject()
        weak var weakOwner = owner

        scheduler.startIfIdle(every: .seconds(60)) { [owner] in
            _ = owner
        }
        owner = nil
        #expect(weakOwner != nil)

        scheduler.cancel()
        #expect(weakOwner == nil)
    }
}
