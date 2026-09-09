import Testing
@testable import CmuxHive

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct HiveMirrorRebindCoordinatorTests {
    @Test func tearingDownTheRouteObserverDoesNotCancelItsReplacement() async throws {
        let coordinator = HiveMirrorRebindCoordinator<String>()
        let rebound = AsyncStream<Bool>.makeStream()
        defer { rebound.continuation.finish(); coordinator.cancelAll() }
        var obsoleteObserver: Task<Void, Never>?
        obsoleteObserver = Task {
            let replacement = coordinator.rebind(key: "device/window") {
                obsoleteObserver?.cancel()
                rebound.continuation.yield(!Task.isCancelled)
            }
            await replacement.value
        }
        var results = rebound.stream.makeAsyncIterator()
        #expect(try #require(await results.next()))
        #expect(obsoleteObserver?.isCancelled == true)
        await obsoleteObserver?.value
    }

    @Test func olderCompletionCannotDropTheSuccessorsCancellationHandle() async throws {
        let coordinator = HiveMirrorRebindCoordinator<String>()
        let firstStarted = AsyncStream<Void>.makeStream()
        let secondStarted = AsyncStream<Void>.makeStream()
        let firstGate = AsyncStream<Void>.makeStream()
        let secondGate = AsyncStream<Void>.makeStream()
        let cancellation = AsyncStream<Bool>.makeStream()
        defer {
            coordinator.cancelAll()
            firstGate.continuation.finish(); secondGate.continuation.finish()
            firstStarted.continuation.finish(); secondStarted.continuation.finish()
            cancellation.continuation.finish()
        }
        let first = coordinator.rebind(key: "device/window") {
            firstStarted.continuation.yield(())
            for await _ in firstGate.stream { break }
        }
        var firstReady = firstStarted.stream.makeAsyncIterator()
        _ = try #require(await firstReady.next())
        let second = coordinator.rebind(key: "device/window") {
            secondStarted.continuation.yield(())
            for await _ in secondGate.stream { break }
            cancellation.continuation.yield(Task.isCancelled)
        }
        await first.value
        var secondReady = secondStarted.stream.makeAsyncIterator()
        _ = try #require(await secondReady.next())
        coordinator.cancelAll { $0 == "device/window" }
        // Finish even if a broken owner lost its handle, so the test fails without hanging.
        secondGate.continuation.finish()
        await second.value
        var results = cancellation.stream.makeAsyncIterator()
        #expect(try #require(await results.next()))
    }
}
