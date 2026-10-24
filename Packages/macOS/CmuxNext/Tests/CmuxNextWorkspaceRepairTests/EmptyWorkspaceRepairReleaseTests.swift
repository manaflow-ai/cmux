import CmuxNextDaemon
import Foundation
@testable import CmuxNextWorkspaceRepair
import Testing

/// The repair's nonisolated deinit cancels its store observation and every workspace watcher on the
/// thread that releases it, main or not. It used to return early off the main thread (`guard
/// Thread.isMainThread else { return }`), so a repair released off main left its loops waiting.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct EmptyWorkspaceRepairReleaseTests {
    // crash-allow: the other thread writes `repair` once while the main thread waits on the semaphore, so no two threads touch it at once.
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
        await EmptyWorkspaceRepairCostTests.settle { handoff.repair?.watchers.count == 3 }
        let observation = try #require(handoff.repair?.observation)
        let watchers = Array(try #require(handoff.repair?.watchers.values))
        #expect(watchers.count == 3)
        if offMain {
            Self.releaseOnAnotherThread(handoff)
        } else {
            handoff.repair = nil
        }
        #expect(observation.isCancelled, "releasing the repair left its store observation running")
        #expect(watchers.allSatisfy(\.isCancelled), "releasing the repair left a workspace watcher running")
    }

    /// Drops the handoff's repair, its last reference, on a new thread and returns once it is gone.
    /// The main thread waits meanwhile, so a deinit that needs the main thread cannot clean up first.
    nonisolated static func releaseOnAnotherThread(_ handoff: Handoff) {
        let released = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            handoff.repair = nil
            released.signal()
        }
        released.wait()
    }
}
