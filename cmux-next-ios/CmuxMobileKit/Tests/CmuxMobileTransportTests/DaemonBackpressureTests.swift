import Foundation
import Testing
@testable import CmuxMobileTransport

@Suite(.timeLimit(.minutes(1))) struct DaemonBackpressureTests {
    @Test func slowEventReaderStopsReceivingFromTheLink() async throws {
        let line = Data(#"{"event":"output"}"#.utf8)
        let channel = BackpressureChannel()
        for _ in 0..<3 { channel.deliver(line + Data([0x0A])) }
        let client = DaemonClient(channel: channel, eventCapacity: line.count)
        await client.start()
        try await Task.sleep(for: .milliseconds(50))
        // One buffered event and one blocked enqueue; the third frame stays
        // at the link until the application consumes the first event.
        #expect(channel.readCount == 2)
        var events = client.events.makeAsyncIterator()
        #expect(await events.next() == line)
        try await Task.sleep(for: .milliseconds(50))
        #expect(channel.readCount == 3)
        await client.close()
        #expect(await events.next() == line)
        #expect(await events.next() == nil)
    }

    @Test func closeReleasesABlockedProducerAndCancellationReleasesAReader() async throws {
        let buffer = BoundedDaemonEventBuffer(capacity: 1)
        #expect(await buffer.push(Data([1])))
        let producer = Task { await buffer.push(Data([2])) }
        await buffer.finish()
        #expect(await producer.value == false)

        let empty = BoundedDaemonEventBuffer(capacity: 1)
        let reader = Task { await empty.next() }
        reader.cancel()
        #expect(await reader.value == nil)
        await empty.finish()
    }
}

private final class BackpressureChannel: LinkChannel, @unchecked Sendable {
    let id: UInt32 = 1
    private let lock = NSLock()
    private var reads = 0
    private let stream: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation
    private var iterator: AsyncStream<Data>.Iterator

    init() {
        (stream, continuation) = AsyncStream.makeStream()
        iterator = stream.makeAsyncIterator()
    }
    var readCount: Int { lock.withLock { reads } }
    func send(_ data: Data) async throws {}
    func receive() async throws -> Data? {
        lock.withLock { reads += 1 }
        return await iterator.next()
    }
    func deliver(_ data: Data) { continuation.yield(data) }
    func close(code: String, reason: String) async { continuation.finish() }
}
