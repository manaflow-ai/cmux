import Darwin
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

    @Test("Cancellation wakes a reader blocked on an open pipe")
    func cancellationWakesBlockedReader() async throws {
        var descriptors: [Int32] = [-1, -1]
        try #require(Darwin.pipe(&descriptors) == 0)
        let reader = SimulatorProcessOutputReader(fileDescriptor: descriptors[0])
        Darwin.close(descriptors[0])
        defer { Darwin.close(descriptors[1]) }
        let task = Task {
            for await _ in reader.batches() {}
        }

        await Task.yield()
        reader.cancel()
        await task.value

        // A repeated lifecycle cancellation after EOF must not raise SIGPIPE.
        reader.cancel()
    }
}
