import CmuxNextDaemon
import CmuxNextDaemonService
import Foundation
import Testing

/// A share link the app opens waits for this Mac's daemon only while startup runs (`connectionOnceStarted`): a
/// service never started, or torn down, answers nil at once, so the link reaches its fallback instead of hanging.
@MainActor
struct DaemonConnectionWaitTests {
    /// `work`'s answer, or `.timedOut` when it is still waiting after `limit`.
    enum Outcome: Equatable { case answered(Bool), timedOut }

    func within(_ limit: Duration = .seconds(5), _ work: @escaping @Sendable @MainActor () async -> Bool) async -> Outcome {
        let answer = Task { @MainActor in await work() }
        let deadline = Task {
            try? await Task.sleep(for: limit)
            return !Task.isCancelled
        }
        // Whichever ends first: the answer cancels the deadline; a deadline that passes leaves the answer waiting.
        let answered = Task { @MainActor in
            let value = await answer.value
            deadline.cancel()
            return value
        }
        if await deadline.value { return .timedOut }
        return .answered(await answered.value)
    }

    @Test func aServiceNeverStartedAnswersNilAtOnce() async {
        let service = DaemonService()
        #expect(await within { await service.connectionOnceStarted() == nil } == .answered(true))
    }

    @Test func aTeardownResumesEveryWaiter() async {
        let service = DaemonService()
        let waiting = Task { @MainActor in await service.firstConnection() }
        await Task.yield()
        service.shutdownConnection()
        #expect(await within { await waiting.value; return true } == .answered(true))
    }
}
