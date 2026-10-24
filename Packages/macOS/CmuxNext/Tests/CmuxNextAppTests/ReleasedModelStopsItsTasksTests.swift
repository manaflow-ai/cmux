import CmuxNextFilesUI
@testable import CmuxNextApp
import Foundation
import Testing
import CmuxNextWakeupsTestSupport

/// A model's nonisolated deinit stops the tasks it owns on the thread that releases it, main or not.
/// The App's deinits used to return early off the main thread (`guard Thread.isMainThread else
/// { return }`), so a model released off main left its waiting search (or observation loop) running
/// for good. ``FindSectionModel`` stands for every owner of that shape: its search waits out the
/// typing pause on an injected clock, so the test sees whether the release cancelled it.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct ReleasedModelStopsItsTasksTests {
    // crash-allow: the other thread writes `model` once while the main thread waits on the semaphore, so no two threads touch it at once.
    nonisolated final class Handoff: @unchecked Sendable {
        var model: FindSectionModel?
    }

    static let root = URL(fileURLWithPath: "/tmp/project", isDirectory: true)

    @Test func releasingTheModelOnMainCancelsItsWaitingSearch() async throws {
        let clock = ManualClock()
        var asked: [String] = []
        let handoff = Handoff()
        handoff.model = FindSectionModel(search: { query, _ in
            asked.append(query)
            return .matches([], limited: false)
        }, clock: clock)
        handoff.model?.setRoot(Self.root)
        handoff.model?.type("needle")
        try await clock.waitForSleeper()
        let pending = try #require(handoff.model?.pendingSearch)
        handoff.model = nil
        #expect(pending.isCancelled, "releasing the model on main left its search waiting")
        clock.advance(by: FindSectionModel.debounce)
        await pending.value
        #expect(asked.isEmpty, "a released model's search ran")
    }

    @Test func releasingTheModelOffMainCancelsItsWaitingSearch() async throws {
        let clock = ManualClock()
        var asked: [String] = []
        let handoff = Handoff()
        handoff.model = FindSectionModel(search: { query, _ in
            asked.append(query)
            return .matches([], limited: false)
        }, clock: clock)
        handoff.model?.setRoot(Self.root)
        handoff.model?.type("needle")
        try await clock.waitForSleeper()
        let pending = try #require(handoff.model?.pendingSearch)
        Self.releaseOnAnotherThread(handoff)
        #expect(pending.isCancelled, "releasing the model off main left its search waiting")
        clock.advance(by: FindSectionModel.debounce)
        await pending.value
        #expect(asked.isEmpty, "a released model's search ran")
    }

    /// Drops the handoff's model, its last reference, on a new thread and returns once it is gone.
    /// The main thread waits meanwhile, so a deinit that needs the main thread cannot clean up first.
    nonisolated static func releaseOnAnotherThread(_ handoff: Handoff) {
        let released = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            handoff.model = nil
            released.signal()
        }
        released.wait()
    }
}
