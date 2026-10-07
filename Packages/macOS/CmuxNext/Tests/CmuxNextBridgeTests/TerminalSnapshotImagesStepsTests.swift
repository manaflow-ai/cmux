import CmuxNextBridge
import CmuxNextDaemon
import Foundation
import Testing

/// S3k: an images chunk is a restore step like history: bulk for
/// backpressure, and replaced by a newer READY.
@Suite struct TerminalSnapshotImagesStepsTests {
    let images = TerminalSnapshotFrame(phase: .images, generation: 3, offset: 40, version: 1, data: Data(count: 8))
    let ready = TerminalSnapshotFrame(phase: .ready, generation: 4, offset: 60, version: 1, cols: 80, rows: 24, data: Data("R".utf8))

    @Test func imagesAreOnlyARestore() {
        #expect(TerminalStreamPlan.steps(for: .snapshot(images)) == [.snapshot(images)])
    }

    @Test func aReadyDropsQueuedImagesAndImagesCountAsBulk() async {
        let queue = TerminalStepQueue(highWater: 1 << 20)
        await queue.push(.snapshot(images))
        #expect(queue.bufferedOutputBytes == 8)
        await queue.push(.grid(columns: 80, rows: 24))
        await queue.push(.snapshot(ready))
        queue.finish()
        var steps: [TerminalStreamPlan.Step] = []
        while let step = await queue.next() { steps.append(step) }
        #expect(steps == [.grid(columns: 80, rows: 24), .snapshot(ready)])
    }
}
