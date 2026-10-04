import CmuxNextBridge
import CmuxNextDaemon
import Foundation
import Testing

/// Snapshot attach (S2b): a READY snapshot is the grid change and the
/// content in one event; history adds its scrollback. The view restores both
/// on the same surface, so no step here asks for a fresh one.
@Suite(.timeLimit(.minutes(1)))
struct TerminalSnapshotStepsTests {
    typealias Driver = TerminalAttachDriver<FakeLink>

    let ready = TerminalSnapshotFrame(phase: .ready, generation: 3, offset: 40, version: 1,
                                      cols: 100, rows: 30, data: Data("READY".utf8))
    let history = TerminalSnapshotFrame(phase: .history, generation: 3, offset: 40, version: 1,
                                        data: Data("PAGES".utf8))

    @Test func readyLocksItsGridBeforeTheRestore() {
        #expect(TerminalStreamPlan.steps(for: .snapshot(ready)) == [.grid(columns: 100, rows: 30), .snapshot(ready)])
    }

    @Test func historyIsOnlyARestore() {
        #expect(TerminalStreamPlan.steps(for: .snapshot(history)) == [.snapshot(history)])
    }

    @Test func aReadySupersedesQueuedOutputAndHistory() async {
        let queue = TerminalStepQueue(highWater: 1 << 20)
        await queue.push(.output(Data("old".utf8)))
        await queue.push(.snapshot(history))
        await queue.push(.grid(columns: 100, rows: 30))
        await queue.push(.snapshot(ready))
        await queue.push(.output(Data("new".utf8)))
        queue.finish()
        var steps: [TerminalStreamPlan.Step] = []
        while let step = await queue.next() { steps.append(step) }
        #expect(steps == [.grid(columns: 100, rows: 30), .snapshot(ready), .output(Data("new".utf8))])
    }

    /// During a resize drag several READYs queue up: only the newest one is
    /// restored (each restore re-applies the config and waits for the lane).
    @Test func aReadyDropsOlderQueuedReadys() async {
        let queue = TerminalStepQueue(highWater: 1 << 20)
        let older = TerminalSnapshotFrame(phase: .ready, generation: 2, offset: 10, version: 1,
                                          cols: 90, rows: 30, data: Data("OLD".utf8))
        await queue.push(.grid(columns: 90, rows: 30))
        await queue.push(.snapshot(older))
        await queue.push(.status(.connected))
        await queue.push(.grid(columns: 100, rows: 30))
        await queue.push(.snapshot(ready))
        queue.finish()
        var steps: [TerminalStreamPlan.Step] = []
        while let step = await queue.next() { steps.append(step) }
        #expect(steps == [.grid(columns: 90, rows: 30), .status(.connected), .grid(columns: 100, rows: 30), .snapshot(ready)])
    }

    /// History is bulk data: it counts toward the high-water mark like output,
    /// while a READY never waits (it supersedes what is queued).
    @Test func historyCountsTowardBackpressure() async {
        let queue = TerminalStepQueue(highWater: 4)
        let pages = TerminalSnapshotFrame(phase: .history, generation: 3, offset: 40, version: 1, data: Data(count: 8))
        await queue.push(.snapshot(pages))
        #expect(queue.bufferedOutputBytes == 8)
        await queue.push(.snapshot(ready))
        #expect(queue.bufferedOutputBytes == 0)
        queue.finish()
    }

    /// The first READY of a link is its replay: the view goes live and
    /// queued input follows it.
    @Test func aReadySnapshotMakesTheLinkLive() async {
        let link = FakeLink(id: 1)
        let driver = Driver(initialSize: CellSize(cols: 100, rows: 30), opener: { _ in
            link.emit(.snapshot(TerminalSnapshotFrame(phase: .ready, generation: 1, offset: 0, version: 1,
                                                      cols: 100, rows: 30, data: Data("READY".utf8))))
            return link
        })
        driver.input(Data("x".utf8))
        driver.start()
        // Steps until the restore (grid first); a status step may come between.
        // The step queue ignores task cancellation: a guard ends it instead.
        let guardTask = Task {
            try? await Task.sleep(for: .seconds(20))
            driver.cancelSteps()
        }
        defer { guardTask.cancel() }
        var steps: [TerminalStreamPlan.Step] = []
        while let step = await driver.nextStep() {
            steps.append(step)
            if case .snapshot = step { break }
        }
        #expect(steps.first == .grid(columns: 100, rows: 30))
        #expect(steps.contains { if case .snapshot = $0 { true } else { false } })
        for _ in 0..<2000 where link.input.isEmpty {
            try? await Task.sleep(for: .milliseconds(2))
        }
        #expect(driver.machine.liveLink?.link === link)
        #expect(link.input == Data("x".utf8))
        driver.close()
    }
}
