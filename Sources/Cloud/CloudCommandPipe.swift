import Darwin
import Foundation

/// Owns a cancellable dispatch I/O read and closes its descriptor before publishing completion.
/// Safety: DispatchIO and AsyncStream are thread-safe; all captured bytes are local to `read`.
final class CloudCommandPipe: @unchecked Sendable {
    private struct Chunk: Sendable {
        let data: Data
        let error: Int32
    }
    private let channel: DispatchIO
    private let chunks: AsyncStream<Chunk>
    private let closed = CloudLinkFirstValue<Bool>()

    init(descriptor: Int32) {
        let (chunks, continuation) = AsyncStream<Chunk>.makeStream()
        self.chunks = chunks
        // Serial delivery preserves byte order. This queue delivers the legacy I/O events;
        // it does not synchronize domain state or block a cooperative executor on read(2).
        let queue = DispatchQueue(label: "com.cmux.cloud.command-pipe", qos: .userInitiated)
        let closed = closed
        channel = DispatchIO(type: .stream, fileDescriptor: descriptor, queue: queue) { _ in
            Darwin.close(descriptor)
            closed.resolve(true)
        }
        channel.setLimit(lowWater: 1)
        channel.read(offset: 0, length: Int.max, queue: queue) { done, data, error in
            if let data, !data.isEmpty { continuation.yield(Chunk(data: Data(data), error: 0)) }
            if error != 0 { continuation.yield(Chunk(data: Data(), error: error)) }
            if done { continuation.finish() }
        }
    }

    func read() async -> (data: Data, error: Int32?) {
        var data = Data()
        var error: Int32?
        for await chunk in chunks {
            data.append(chunk.data)
            if chunk.error != 0 { error = chunk.error }
        }
        channel.close()
        _ = await closed.result
        return (data, error)
    }

    func stop() { channel.close(flags: .stop) }
}
