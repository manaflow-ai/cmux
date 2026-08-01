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
        let result = await stream.yield(body)
        #expect(result == .enqueued)
        #expect(await stream.storage.retainedBufferedBytes == body.count)

        var iterator = stream.makeAsyncIterator()
        #expect(await iterator.next() == body)
        #expect(await stream.storage.retainedBufferedBytes == 0)
    }

    @Test("Consuming a large body releases it while a later message stays queued")
    func partialDrainReleasesConsumedBody() async throws {
        let stream = SimulatorWebInspectorMessageStream(
            maximumBufferedBytes: 1_024 * 1_024 + 1
        )
        let largeBody = Data(repeating: 0x41, count: 1_024 * 1_024)
        let trailingBody = Data([0x42])
        let largeResult = await stream.yield(largeBody)
        let trailingResult = await stream.yield(trailingBody)
        #expect(largeResult == .enqueued)
        #expect(trailingResult == .enqueued)

        var iterator = stream.makeAsyncIterator()
        #expect(await iterator.next() == largeBody)
        #expect(await stream.storage.retainedBufferedBytes == trailingBody.count)
        #expect(await iterator.next() == trailingBody)
    }

    @Test("Empty protocol bodies terminate the stream")
    func emptyBodyTerminatesStream() async {
        let stream = SimulatorWebInspectorMessageStream(
            maximumBufferedBytes: 1_024 * 1_024
        )

        #expect(await stream.yield(Data()) == .overflow)
        #expect(await stream.yield(Data([0x41])) == .terminated)
    }

    @Test("Tiny messages cannot bypass the bounded queue")
    func tinyMessageCountIsBounded() async {
        let stream = SimulatorWebInspectorMessageStream(
            maximumBufferedBytes: 1_024 * 1_024
        )
        for _ in 0..<4_096 {
            #expect(await stream.yield(Data([0x41])) == .enqueued)
        }

        #expect(await stream.yield(Data([0x42])) == .overflow)
        #expect(await stream.yield(Data([0x43])) == .terminated)
    }
}
