import CmuxNextDaemon
import Foundation
@testable import CmuxNextWorkspaceRepair
import Testing

/// The repair's nonisolated deinit cancels its store observation and every workspace watcher on the
/// thread that releases it, main or not. It used to return early off the main thread (`guard
/// Thread.isMainThread else { return }`), so a repair released off main left its loops waiting.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct EmptyWorkspaceRepairReleaseTests {
    // crash-allow: the other thread writes `repair` once while the test awaits that thread's resume, so no two threads touch it at once.
    nonisolated final class Handoff: @unchecked Sendable {
        var repair: EmptyWorkspaceRepair?
    }

    @Test(arguments: [false, true])
    func releasingTheRepairCancelsItsObservations(offMain: Bool) async throws {
        let store = DaemonStore()
        store.apply(snapshot: DaemonTree(workspaceRevision: 1, workspaces: (1...3).map { EmptyWorkspaceRepairCostTests.workspace($0) }))
        let handoff = Handoff()
        handoff.repair = EmptyWorkspaceRepair(store: store, create: { _ in nil }, close: { _ in }, cause: { _ in .tabClosed },
                                              canCreate: { true }, epoch: { 1 }, isLive: { true })
        await EmptyWorkspaceRepairCostTests.settle { handoff.repair?.observationTasksForTests.count == 4 }
        let tasks = try #require(handoff.repair?.observationTasksForTests)
        #expect(tasks.count == 4, "expected the store observation and one watcher per workspace")
        if offMain {
            await Self.releaseOnAnotherThread(handoff)
        } else {
            handoff.repair = nil
        }
        #expect(tasks.allSatisfy(\.isCancelled), "releasing the repair left an observation running")
    }

    /// Drops the handoff's repair, its last reference, on a new thread and resumes once it is gone.
    /// The test awaits instead of blocking, so the main actor stays free while the other thread runs the deinit.
    nonisolated static func releaseOnAnotherThread(_ handoff: Handoff) async {
        await withCheckedContinuation { (released: CheckedContinuation<Void, Never>) in
            Thread.detachNewThread {
                handoff.repair = nil
                released.resume()
            }
        }
    }
}
