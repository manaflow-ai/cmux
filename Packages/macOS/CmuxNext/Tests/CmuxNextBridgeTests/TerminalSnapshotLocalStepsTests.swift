import CmuxNextBridge
import CmuxNextDaemon
import Foundation
import Testing

/// S2c: a local-history READY is ordered with the output before it. It must
/// never drop queued output (the view's reflow needs every byte before the
/// cut), and it locks no grid of its own (the restore takes the new grid).
@Suite(.timeLimit(.minutes(1)))
struct TerminalSnapshotLocalStepsTests {
    let local = TerminalSnapshotFrame(phase: .ready, generation: 4, offset: 50, version: 1, cols: 25, rows: 10,
                                      localHistory: TerminalLocalHistoryCheck(rows: 9, digest: Data([1, 2])),
                                      data: Data("READY".utf8))

    @Test func aLocalReadyIsOnlyARestore() {
        #expect(TerminalStreamPlan.steps(for: .snapshot(local)) == [.snapshot(local)])
    }

    @Test func aLocalReadyKeepsQueuedOutput() async {
        let queue = TerminalStepQueue(highWater: 1 << 20)
        await queue.push(.output(Data("before".utf8)))
        await queue.push(.snapshot(local))
        await queue.push(.output(Data("after".utf8)))
        queue.finish()
        var steps: [TerminalStreamPlan.Step] = []
        while let step = await queue.next() { steps.append(step) }
        #expect(steps == [.output(Data("before".utf8)), .snapshot(local), .output(Data("after".utf8))])
    }

    /// The view asks for a fresh READY + history (reason gap) on the live link.
    @Test func aResyncRequestReachesTheLiveLink() async {
        let link = FakeLink(id: 1)
        let driver = TerminalAttachDriver<FakeLink>(initialSize: CellSize(cols: 25, rows: 10), opener: { _ in
            link.emit(.snapshot(TerminalSnapshotFrame(phase: .ready, generation: 1, offset: 0, version: 1,
                                                      cols: 25, rows: 10, data: Data("R".utf8))))
            return link
        })
        driver.start()
        for _ in 0..<2000 where driver.machine.liveLink == nil {
            try? await Task.sleep(for: .milliseconds(2))
        }
        driver.requestResync()
        #expect(link.commands.contains("snapshot-request gap"))
        driver.close()
    }
}
