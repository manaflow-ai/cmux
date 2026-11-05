import CmuxNextCompat
import Darwin
import Dispatch
import Foundation

/// Event-driven private socket I/O, with bounded chunks and fatal overflow.
actor NativeBrokerStream {
    nonisolated let chunks: AsyncThrowingStream<Data, any Error>
    private let channel: DispatchIO
    private let continuation: AsyncThrowingStream<Data, any Error>.Continuation

    init(descriptor: Int32) {
        let queue = DispatchQueue.global(qos: .utility)
        channel = DispatchIO(type: .stream, fileDescriptor: descriptor, queue: queue) { _ in Darwin.close(descriptor) }
        (chunks, continuation) = AsyncThrowingStream.makeStream(of: Data.self, bufferingPolicy: .bufferingOldest(16))
        channel.setLimit(lowWater: 1)
        channel.setLimit(highWater: 4096)
        let continuation = continuation
        channel.read(offset: 0, length: Int.max, queue: queue) { [weak channel] done, bytes, error in
            if let bytes, !bytes.isEmpty {
                if case .dropped = continuation.yield(Data(bytes)) {
                    channel?.close(flags: .stop)
                    continuation.finish(throwing: POSIXError(.ENOBUFS))
                }
            }
            if error != 0 { continuation.finish(throwing: POSIXError(POSIXErrorCode(rawValue: error) ?? .EIO)) }
            else if done { continuation.finish() }
        }
    }

    func send(_ data: Data) async throws {
        guard !data.isEmpty, data.count <= 65_536 else { throw POSIXError(.EMSGSIZE) }
        let channel = channel
        let bytes = data.withUnsafeBytes { DispatchData(bytes: $0) }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (answer: CheckedContinuation<Void, any Error>) in
                // concurrency-allow: short synchronous compare-and-set; DispatchIO may call back more than once.
                let answered = Mutex(false)
                channel.write(offset: 0, data: bytes, queue: .global(qos: .utility)) { done, _, error in
                    guard done || error != 0, answered.withLock({ state in if state { return false }; state = true; return true }) else { return }
                    if error == 0 { answer.resume() }
                    else { answer.resume(throwing: POSIXError(POSIXErrorCode(rawValue: error) ?? .EIO)) }
                }
            }
        } onCancel: { channel.close(flags: .stop) }
    }

    func close() {
        continuation.finish()
        channel.close(flags: .stop)
    }

    deinit { continuation.finish(); channel.close(flags: .stop) }
}
