import CmuxNextWakeups
import Foundation
@testable import CmuxNextSidebar
import Testing

/// `SidebarDocStore.show` in chunks (p06-scheduler-200, feature `sidebarDocChunkedShow`): a show of 400 rows is built
/// as visible tasks on the main-thread scheduler that stop when `MainFrameBudget.shouldYield()` says so, keep to the
/// visible share of each frame, and end with the same projection a show at once makes.
@MainActor @Suite(.serialized) struct SidebarDocChunkedShowTests {
    typealias Fixture = SidebarDocReorderProjectionCostTests

    /// While a person's key stays pending, every task of the show runs one unit and yields: the reducer's `view` call,
    /// then one chunk of 32 rows per task (13 for 400 rows). `shown` keeps the old projection until the last chunk, and
    /// the show's `then` gets the new one once.
    @Test func aShowOf400RowsYieldsAfterEachChunkWhileAKeyIsPending() async throws {
        let store = try await Fixture.loaded()
        let clock = ChunkClock()
        let input = ChunkInput()
        let work = MainWorkScheduler.testing(budget: MainFrameBudget(input: input, uptimeNanos: clock.read)) { _ in ChunkLink() }
        let keeper = ChunkLinkKeeper(on: work)
        store.showInChunks(on: work)
        let live = Fixture.placed.map(Fixture.ref)
        var told: [SidebarDocProjection?] = []
        input.pending = true
        store.show(live: live) { told.append($0) }
        #expect(store.shown == nil && told.isEmpty, "a chunked show built its projection inline")
        var frames = 0
        while told.isEmpty, frames < 200 {
            frames += 1
            clock.advance(ms: 17)
            work.frameDidFire(timestamp: Double(frames), refreshInterval: 1.0 / 60)
        }
        let chunks = (Fixture.placed.count + 31) / 32
        #expect(work.budget.stats.tasks[0] == 1 + chunks, "the view call and each chunk of 32 rows are one task each")
        #expect(told.count == 1)
        #expect(told.first.flatMap { $0 } == store.shown)
        #expect(store.shown?.machines[Fixture.session]?.count == Fixture.loose + Fixture.groups)
        Fixture.expectMatchesFreshProjection(store, live: live, "after the chunked show")
        keeper.stop()
    }

    /// On the real clock, with nothing pending, no frame spends more than the visible share on the show of 400 rows,
    /// and a show the memo answers shows at once.
    @Test func aShowOf400RowsNeverExceedsTheVisibleShareOfAFrame() async throws {
        let store = try await Fixture.loaded()
        let work = MainWorkScheduler.testing(budget: MainFrameBudget()) { _ in ChunkLink() }
        let keeper = ChunkLinkKeeper(on: work)
        store.showInChunks(on: work)
        let live = Fixture.placed.map(Fixture.ref)
        var told = 0
        store.show(live: live) { _ in told += 1 }
        var frames = 0
        while told == 0, frames < 200 {
            frames += 1
            work.frameDidFire(timestamp: Double(frames), refreshInterval: 1.0 / 60)
        }
        work.frameDidFire(timestamp: Double(frames + 1), refreshInterval: 1.0 / 60) // rolls the last frame into the stats
        #expect(told == 1)
        #expect(work.budget.stats.maxFrameNanos[0] <= MainFrameBudget.nanos(work.budget.budgets.visible),
                "a frame spent more than the visible share on the show")
        Fixture.expectMatchesFreshProjection(store, live: live, "after the chunked show")

        let tasks = work.budget.stats.tasks[0]
        store.show(live: live) { _ in told += 1 }
        #expect(told == 2, "a show the memo answers waited for a task")
        #expect(work.budget.stats.tasks[0] == tasks)
        keeper.stop()
    }
}

/// A frame-class client that keeps the scheduler's fake link up, so posts wait for hand-fired frames.
@MainActor
private final class ChunkLinkKeeper {
    private let client: FrameClient

    init(on work: MainWorkScheduler) {
        client = FrameClient(owner: "test.keeper", isAnimation: false, on: work.frames) { _ in true }
        client.activate()
    }

    func stop() { client.deactivate() }
}

/// A clock the test moves (`CLOCK_UPTIME_RAW` nanoseconds).
@MainActor
private final class ChunkClock {
    private var now: UInt64 = 1_000_000_000
    var read: () -> UInt64 { { [self] in self.now } }
    func advance(ms: Double) { now += UInt64(ms * 1_000_000) }
}

@MainActor
private final class ChunkInput: InputPendingSource {
    var pending = false
    func hasPendingInput(uptime: TimeInterval) -> Bool { pending }
}

@MainActor
private final class ChunkLink: FrameLink {
    var isPaused = false
    func invalidate() {}
}
