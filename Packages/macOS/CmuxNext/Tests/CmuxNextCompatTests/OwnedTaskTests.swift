import CmuxNextCompat
import Testing

/// ``OwnedTask`` replaces the owners' `nonisolated deinit { guard Thread.isMainThread else { return };
/// MainActor.assumeIsolated { task?.cancel() } }`: releasing the handle is what stops the task now,
/// from any thread, so an observation loop ends with its owner.
@Suite(.timeLimit(.minutes(1)))
struct OwnedTaskTests {
    /// A task that waits on a stream that never yields, and reports whether it ended cancelled.
    private static func waitingTask(reporting ended: AsyncStream<Bool>.Continuation, on gate: AsyncStream<Void>) -> Task<Void, Never> {
        Task {
            for await _ in gate {}
            ended.yield(Task.isCancelled)
            ended.finish()
        }
    }

    @Test func releasingTheHandleCancelsTheTask() async {
        let (gate, open) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        let (ended, report) = AsyncStream.makeStream(of: Bool.self, bufferingPolicy: .bufferingNewest(1))
        var handle: OwnedTask? = OwnedTask(Self.waitingTask(reporting: report, on: gate))
        handle = nil
        var iterator = ended.makeAsyncIterator()
        #expect(await iterator.next() == true, "the observation loop stops once its handle is released")
        withExtendedLifetime(open) {}
        #expect(handle == nil)
    }

    @Test func cancelStopsTheTaskWhileTheHandleLives() async {
        let (gate, open) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        let (ended, report) = AsyncStream.makeStream(of: Bool.self, bufferingPolicy: .bufferingNewest(1))
        let handle = OwnedTask(Self.waitingTask(reporting: report, on: gate))
        handle.cancel()
        var iterator = ended.makeAsyncIterator()
        #expect(await iterator.next() == true)
        withExtendedLifetime((handle, open)) {}
    }
}
