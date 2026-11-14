import CmuxNextMacScreen
import Testing

@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct CmuxRemoteConfigDeadlineTests {
    /// Before the fix this suspends forever: cancelling the caller cannot remove its continuation.
    @Test func cancelledConfigurationWaitReturnsWithoutSettings() async {
        let service = CmuxRemoteService(connection: { nil })
        let (started, report) = AsyncStream<Bool>.makeStream()
        let waiting = Task { @MainActor in
            report.yield(true)
            return await service.waitAvailable()
        }
        var events = started.makeAsyncIterator()
        #expect(await events.next() == true)
        waiting.cancel()
        #expect(await waiting.value == false)
        report.finish()
    }
}
