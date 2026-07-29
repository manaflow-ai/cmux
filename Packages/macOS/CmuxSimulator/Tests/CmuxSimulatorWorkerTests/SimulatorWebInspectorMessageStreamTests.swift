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
}
