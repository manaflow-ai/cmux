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

    func within(_ limit: Duration = .seconds(5), _ work: @escaping @MainActor () async -> Bool) async -> Outcome {
        await withTaskGroup(of: Outcome.self) { group in
            group.addTask { @MainActor in .answered(await work()) }
            group.addTask {
                try? await Task.sleep(for: limit)
                return .timedOut
            }
            let first = await group.next() ?? .timedOut
            group.cancelAll()
            return first
        }
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
