import CmuxNextCompat
import CmuxNextControl
import CmuxNextPages
import Testing

/// A workspace or tab switch that shows N cmux pages that never showed made N CEF tabs in the
/// switch's own turn (each `makeReadyTab` and `createBrowser` on the main thread), ahead of the
/// switch's commit (perf-lead.md F3 review). The host now makes each page's CEF tab at the start
/// of a later display frame, one page per frame.
@MainActor
struct ChromiumPageFrameBudgetTests {
    /// A frame source the test fires by hand (as CmuxNextControlTests' ManualFrameSource).
    private final class SteppedFrames: ControlFrameSource {
        // Lock carve-out: `scheduleFrame` is a nonisolated, synchronous requirement of the protocol.
        private let pending = Mutex<[@MainActor @Sendable () -> Void]>([])

        func scheduleFrame(_ work: @escaping @MainActor @Sendable () -> Void) {
            pending.withLock { $0.append(work) }
        }

        var scheduledCount: Int { pending.withLock { $0.count } }

        /// Runs the frame callbacks scheduled so far.
        @MainActor
        func fire() {
            let works = pending.withLock { works in
                defer { works.removeAll() }
                return works
            }
            for work in works { work() }
        }
    }

    @MainActor
    private final class Starts {
        var started: [Int] = []
    }

    private func settle(until done: () -> Bool) async {
        for _ in 0..<1_000 where !done() { await Task.yield() }
    }

    @Test func eachPageStartTakesItsOwnLaterFrame() async {
        let frames = SteppedFrames()
        let budget = ChromiumPageFrameBudget(scheduleFrame: frames.scheduleFrame)
        let starts = Starts()
        let first = Task { @MainActor in
            await budget.nextFrame()
            starts.started.append(1)
        }
        let second = Task { @MainActor in
            await budget.nextFrame()
            starts.started.append(2)
        }
        await settle { budget.waitingCount == 2 }
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
