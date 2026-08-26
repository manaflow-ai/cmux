import Testing
@testable import CmuxFoundation

@Suite(.serialized)
struct MainActorDeferredActionSchedulerTests {
    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func newestZeroDelayActionWinsReplacementBurst() async throws {
        let actionCount = 5_000
        let actions = AsyncStream<Int>.makeStream()
        defer { actions.continuation.finish() }
        var actionIterator = actions.stream.makeAsyncIterator()
        let scheduler = MainActorDeferredActionScheduler()

        for identifier in 0..<actionCount {
            scheduler.schedule {
                actions.continuation.yield(identifier)
            }
        }

        let firedIdentifier = try #require(await actionIterator.next())
        #expect(firedIdentifier == actionCount - 1)
        #expect(!scheduler.isScheduled)
    }

    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func cancellationDropsDelayedActionBeforeSuccessor() async throws {
        let actions = AsyncStream<Int>.makeStream()
        defer { actions.continuation.finish() }
        var actionIterator = actions.stream.makeAsyncIterator()
        let scheduler = MainActorDeferredActionScheduler()

        scheduler.schedule(after: .seconds(60)) {
            actions.continuation.yield(1)
        }
        #expect(scheduler.isScheduled)
        scheduler.cancel()
        #expect(!scheduler.isScheduled)

        scheduler.schedule {
            actions.continuation.yield(2)
        }

        let firedIdentifier = try #require(await actionIterator.next())
        #expect(firedIdentifier == 2)
        #expect(!scheduler.isScheduled)
    }

    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func actionCanScheduleItsSuccessor() async throws {
        let actions = AsyncStream<Int>.makeStream()
        defer { actions.continuation.finish() }
        var actionIterator = actions.stream.makeAsyncIterator()
        let scheduler = MainActorDeferredActionScheduler()

        scheduler.schedule {
            actions.continuation.yield(1)
            scheduler.schedule {
                actions.continuation.yield(2)
            }
        }

        let firstIdentifier = try #require(await actionIterator.next())
        let secondIdentifier = try #require(await actionIterator.next())
        #expect(firstIdentifier == 1)
        #expect(secondIdentifier == 2)
        #expect(!scheduler.isScheduled)
    }
}
