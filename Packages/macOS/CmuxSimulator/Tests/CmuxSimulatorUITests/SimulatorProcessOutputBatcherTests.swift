import Foundation
import Testing
@testable import CmuxSimulatorUI

@Suite("Simulator process output batching")
struct SimulatorProcessOutputBatcherTests {
    @Test("High-volume output is decoded in bounded batches")
    func highVolumeOutput() {
        let expected = (0..<10_000).map { "line-\($0)\n" }
        let data = Data(expected.joined().utf8)
        var batcher = SimulatorProcessOutputBatcher()
        var batches: [[String]] = []

        for offset in stride(from: 0, to: data.count, by: 7_777) {
            batches += batcher.append(data[offset..<min(offset + 7_777, data.count)])
        }
        if let final = batcher.finish() { batches.append(final) }

        #expect(batches.allSatisfy { $0.count <= 32 })
        #expect(batches.flatMap { $0 } == expected)
    }

    @Test("An unterminated line is capped before final delivery")
    func capsUnterminatedLine() {
        var batcher = SimulatorProcessOutputBatcher()
        _ = batcher.append(Data(repeating: 65, count: 100_000))

        let line = batcher.finish()?.first

        #expect(line?.utf8.count == 64 * 1_024)
    }
}
