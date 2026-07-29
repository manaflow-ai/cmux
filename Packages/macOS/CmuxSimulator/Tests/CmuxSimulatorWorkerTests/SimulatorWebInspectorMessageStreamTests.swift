import Foundation
import Testing

@testable import CmuxSimulatorWorker

@Suite("Web Inspector message stream")
struct SimulatorWebInspectorMessageStreamTests {
    @Test("Consuming the last message releases its retained body")
    func drainedQueueReleasesRetainedBody() async throws {
        let stream = SimulatorWebInspectorMessageStream(
            maximumBufferedBytes: 1_024 * 1_024
        )
        let body = Data(repeating: 0x41, count: 1_024 * 1_024)
        #expect(stream.yield(body) == .enqueued)
        #expect(stream.retainedBufferedBytesForTesting == body.count)

        var iterator = stream.makeAsyncIterator()
        #expect(await iterator.next() == body)
        #expect(stream.retainedBufferedBytesForTesting == 0)
    }

    @Test("Consuming a large body releases it while a later message stays queued")
    func partialDrainReleasesConsumedBody() async throws {
        let stream = SimulatorWebInspectorMessageStream(
            maximumBufferedBytes: 1_024 * 1_024 + 1
        )
        let largeBody = Data(repeating: 0x41, count: 1_024 * 1_024)
        let trailingBody = Data([0x42])
        #expect(stream.yield(largeBody) == .enqueued)
        #expect(stream.yield(trailingBody) == .enqueued)

        var iterator = stream.makeAsyncIterator()
        #expect(await iterator.next() == largeBody)
        #expect(stream.retainedBufferedBytesForTesting == trailingBody.count)
        #expect(await iterator.next() == trailingBody)
    }
}
