import Darwin
import Dispatch
import Foundation

/// DispatchIO owns readiness and cancellation for a process descriptor. Its
/// immutable, thread-safe channel is the only unchecked Sendable boundary.
final class ChromiumPipeIO: @unchecked Sendable {
    private let channel: DispatchIO
    private let queue = DispatchQueue.global(qos: .userInitiated)

    init(descriptor: Int32) {
        channel = DispatchIO(type: .stream, fileDescriptor: descriptor, queue: queue) { _ in
            Darwin.close(descriptor)
        }
        channel.setLimit(lowWater: 1)
        channel.setLimit(highWater: 64 * 1024)
    }

    deinit { channel.close(flags: .stop) }

    func close() { channel.close(flags: .stop) }

    func chunks() -> AsyncThrowingStream<Data, any Error> {
        let pair = AsyncThrowingStream<Data, any Error>.makeStream(bufferingPolicy: .bufferingOldest(64))
        let channel = channel
        pair.continuation.onTermination = { _ in channel.close(flags: .stop) }
        channel.read(offset: 0, length: Int.max, queue: queue) { done, bytes, error in
            if error != 0 {
                pair.continuation.finish(throwing: POSIXError(POSIXErrorCode(rawValue: error) ?? .EIO))
                return
            }
            if let bytes, !bytes.isEmpty,
               case .dropped = pair.continuation.yield(Data(bytes)) {
                pair.continuation.finish(throwing: CDPError.malformedMessage)
                channel.close(flags: .stop)
                return
            }
            if done { pair.continuation.finish() }
        }
        return pair.stream
    }

    func write(_ data: Data) async throws {
        let channel = channel
        try Task.checkCancellation()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let bytes = data.withUnsafeBytes { DispatchData(bytes: $0) }
            channel.write(offset: 0, data: bytes, queue: queue) { done, _, error in
                guard done else { return }
                if error == 0 { continuation.resume() }
                else { continuation.resume(throwing: POSIXError(POSIXErrorCode(rawValue: error) ?? .EIO)) }
            }
        }
    }
}
