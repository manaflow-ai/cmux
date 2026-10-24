import CmuxNextDaemon
import Foundation
@testable import CmuxNextWorkspaceRepair
import Testing

/// The repair's nonisolated deinit cancels its store observation and every workspace watcher on the
/// thread that releases it, main or not. It used to return early off the main thread (`guard
/// Thread.isMainThread else { return }`), so a repair released off main left its loops waiting.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct EmptyWorkspaceRepairReleaseTests {
    // crash-allow: the other thread writes `repair` and `releasedThere` once while the main thread waits on the semaphore, so no two threads touch them at once.
    nonisolated final class Handoff: @unchecked Sendable {
        var repair: EmptyWorkspaceRepair?
        /// Whether the repair was deallocated on the releasing thread (its deinit ran there).
        var releasedThere = false
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
            Self.releaseOnAnotherThread(handoff)
            #expect(handoff.releasedThere, "the repair outlived its release on the other thread, so its deinit did not run there")
        } else {
            handoff.repair = nil
        }
        let allCancelled = tasks.allSatisfy { $0.isCancelled }
        #expect(allCancelled, "releasing the repair left an observation running")
    }

    /// Drops the handoff's repair, its last reference, on a new thread, records in `releasedThere`
    /// whether it was deallocated there, and returns once that thread is done. The main thread waits
    /// meanwhile, so no queued watcher iteration on the main actor can hold the repair (`guard let self`)
    /// and run the deinit on main instead.
    nonisolated static func releaseOnAnotherThread(_ handoff: Handoff) {
        // Test-only thread join, not a lock: blocking main is what keeps the main actor's queued iterations out.
        let released = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            weak var probe = handoff.repair
            handoff.repair = nil
            handoff.releasedThere = probe == nil
            released.signal()
        }
        released.wait()
    }
}
