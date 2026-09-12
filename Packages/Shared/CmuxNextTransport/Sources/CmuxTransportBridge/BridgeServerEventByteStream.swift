import CmuxIrohTransport
import Foundation

/// Converts one adopted server-event receive half into ordered, bounded bytes.
public struct BridgeServerEventByteStream: Sendable {
    private let bufferLimit: Int

    /// Creates the adapter with a bounded oldest-first chunk buffer.
    /// - Parameter bufferLimit: The maximum number of unread chunks.
    public init(bufferLimit: Int = 32) {
        self.bufferLimit = max(1, bufferLimit)
    }

    /// Starts the receive pump outside the UI actor.
    /// - Parameter receiveStream: The already-adopted server-event receive half.
    /// - Returns: Ordered payload bytes, failing closed on overflow or read errors.
    public func bytes(from receiveStream: any CmxIrohReceiveStream) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingOldest(bufferLimit)) { continuation in
            let pump = Task { await run(receiveStream, continuation: continuation) }
            continuation.onTermination = { reason in
                pump.cancel()
                let code: UInt64
                switch reason {
                case .finished(let error): code = error == nil ? 0 : 1
                case .cancelled: code = 0
                @unknown default: code = 1
                }
                // AsyncStream invokes this once. Owning STOP_SENDING here
                // avoids contradictory terminal codes from competing paths.
                Task { await receiveStream.stop(errorCode: code) }
            }
        }
    }

    #if compiler(>=6.2)
    @concurrent
    #endif
    private nonisolated func run(
        _ receiveStream: any CmxIrohReceiveStream,
        continuation: AsyncThrowingStream<Data, Error>.Continuation
    ) async {
        do {
            while let chunk = try await receiveStream.receive(maximumByteCount: 1 << 16) {
                switch continuation.yield(chunk) {
                case .enqueued: break
                case .terminated: return
                case .dropped:
                    continuation.finish(throwing: CmxIrohClientServerEventReceiverError.backpressureExceeded)
                    return
                @unknown default:
                    continuation.finish(throwing: CmxIrohClientServerEventReceiverError.backpressureExceeded)
                    return
                }
            }
            continuation.finish()
        } catch {
            continuation.finish(throwing: error)
        }
    }
}
