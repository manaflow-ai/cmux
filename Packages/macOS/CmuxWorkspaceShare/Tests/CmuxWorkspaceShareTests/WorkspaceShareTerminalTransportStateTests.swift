@testable import CmuxWorkspaceShare
import Foundation
import Testing

@Suite
struct WorkspaceShareTerminalFlushBarrierTests {
    @Test
    func defersAndCoalescesLiveFlushesUntilSnapshotFinishes() {
        let first = UUID()
        let second = UUID()
        var barrier = WorkspaceShareTerminalFlushBarrier()

        barrier.beginSnapshot()
        barrier.enqueue([first])
        barrier.enqueue([first, second])

        #expect(barrier.takePendingIfReady().isEmpty)
        barrier.endSnapshot()
        #expect(barrier.takePendingIfReady() == [first, second])
        #expect(barrier.takePendingIfReady().isEmpty)
    }
}

@Suite
struct WorkspaceShareTerminalTransportTrackerTests {
    private let surfaceA = "72C552A7-8F75-4DF3-AC47-3750D01D0C18"
    private let surfaceB = "A8319FD0-0881-45E9-AB76-02D34D4BD1DE"

    @Test
    func selectionChangesPreserveCountersUntilTheSurfaceIsRemoved() throws {
        var tracker = WorkspaceShareTerminalTransportTracker()
        let firstA = try tracker.makeFrame(
            surfaceId: surfaceA,
            kind: .snapshot,
            columns: 80,
            rows: 24,
            data: Data([1])
        )
        let firstB = try tracker.makeFrame(
            surfaceId: surfaceB,
            kind: .snapshot,
            columns: 80,
            rows: 24,
            data: Data([2])
        )

        tracker.prune(keeping: [surfaceA, surfaceB])
        let reselectedA = try tracker.makeFrame(
            surfaceId: surfaceA,
            kind: .snapshot,
            columns: 80,
            rows: 24,
            data: Data([3])
        )

        #expect((firstA.generation, firstA.stateSeq) == (1, 1))
        #expect((firstB.generation, firstB.stateSeq) == (1, 1))
        #expect((reselectedA.generation, reselectedA.stateSeq) == (2, 2))

        tracker.prune(keeping: [surfaceB])
        let recreatedA = try tracker.makeFrame(
            surfaceId: surfaceA,
            kind: .snapshot,
            columns: 80,
            rows: 24,
            data: Data([4])
        )
        #expect((recreatedA.generation, recreatedA.stateSeq) == (1, 1))
    }

    @Test
    func transportSequenceAdvancesOnlyWhenAnEmissionExists() throws {
        var tracker = WorkspaceShareTerminalTransportTracker()
        _ = try tracker.makeFrame(
            surfaceId: surfaceA,
            kind: .snapshot,
            columns: 80,
            rows: 24,
            data: Data([1])
        )

        // An unchanged Ghostty tick never calls makeFrame because the source
        // render-grid emission is nil.
        let changed = try tracker.makeFrame(
            surfaceId: surfaceA,
            kind: .patch,
            columns: 80,
            rows: 24,
            data: Data([2])
        )
        #expect(changed.stateSeq == 2)
    }
}

@Suite
struct WorkspaceSharePendingSendBudgetTests {
    @Test
    func rejectsCountAndByteOverflowUntilQueuedFramesDrain() {
        var budget = WorkspaceSharePendingSendBudget(maximumMessages: 2, maximumBytes: 10)

        let first = budget.reserve(byteCount: 4)
        let second = budget.reserve(byteCount: 6)
        let countOverflow = budget.reserve(byteCount: 1)
        #expect(first)
        #expect(second)
        #expect(!countOverflow)

        budget.release(byteCount: 4)
        let replacement = budget.reserve(byteCount: 4)
        let byteOverflow = budget.reserve(byteCount: 1)
        #expect(replacement)
        #expect(!byteOverflow)

        budget.reset()
        let afterReset = budget.reserve(byteCount: 10)
        #expect(afterReset)
    }
}
