@testable import CmuxNextPages
import Testing

/// A workspace or tab switch that shows N cmux pages that never showed made N CEF tabs in the
/// switch's own turn (each `makeReadyTab` and `createBrowser` on the main thread), ahead of the
/// switch's commit (perf-lead.md F3 review). The host now makes each page's CEF tab at the start
/// of a later display frame, one page per frame.
@MainActor
struct ChromiumPageFrameBudgetTests {
    /// Display frames the test fires by hand.
    @MainActor
    private final class SteppedFrames {
        private var pending: [@MainActor @Sendable () -> Void] = []

        func request(_ work: @escaping @MainActor @Sendable () -> Void) {
            pending.append(work)
        }

        var scheduledCount: Int { pending.count }

        /// Runs the frame callbacks requested so far.
        func fire() {
            let works = pending
            pending.removeAll()
            for work in works { work() }
        }
    }

    @MainActor
    private final class Starts {
        var started: [Int] = []
    }

    /// A page start that waits for its frame. Returns once the start waits: the task signals right
    /// before it calls `nextFrame()`, whose enqueue runs in that same main-actor job, so the test
    /// resumes only after the start is queued (no polling).
    private func start(_ id: Int, budget: ChromiumPageFrameBudget, starts: Starts) async -> Task<Void, Never> {
        let (entered, signal) = AsyncStream<Void>.makeStream()
        let task = Task { @MainActor in
            signal.yield()
            signal.finish()
            await budget.nextFrame()
            starts.started.append(id)
        }
        for await _ in entered {}
        return task
    }

    @Test func eachPageStartTakesItsOwnLaterFrame() async {
        let frames = SteppedFrames()
        let budget = ChromiumPageFrameBudget(requestFrame: { frames.request($0) })
        let starts = Starts()
        let first = await start(1, budget: budget, starts: starts)
        let second = await start(2, budget: budget, starts: starts)
        // The turn that showed the pages makes none of them.
        #expect(budget.waitingCount == 2)
        #expect(starts.started.isEmpty)
        #expect(frames.scheduledCount == 1)

        frames.fire()
        await first.value
        #expect(starts.started == [1])
        // One page per frame: the second waits for the next one.
        #expect(budget.waitingCount == 1)
        #expect(frames.scheduledCount == 1)

        frames.fire()
        await second.value
        #expect(starts.started == [1, 2])
        #expect(frames.scheduledCount == 0)
    }
}
