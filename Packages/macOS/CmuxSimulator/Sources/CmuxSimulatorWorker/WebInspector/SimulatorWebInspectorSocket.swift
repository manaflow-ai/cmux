import Darwin
import Foundation

/// Full-duplex Unix socket whose blocking reader is confined to one thread.
///
/// The immutable descriptor stays open until deinitialization, so shutdown can
/// safely race a read without descriptor reuse. Writes are isolated to the
/// worker's main actor, which is the safety argument for unchecked Sendable.
final class SimulatorWebInspectorSocket: SimulatorWebInspectorTransport, @unchecked Sendable {
    /// Only one decoded plist body may wait behind the consumer. If inspectord
    /// outruns that budget, the worker drops the socket instead of buffering a
    /// burst of potentially 64 MiB frames.
    static let maximumBufferedBodyCount = 1
    static let maximumBufferedBodyBytes = maximumBufferedBodyCount * 64 * 1024 * 1024

    let messages: AsyncStream<Data>

    private let frameCodec: SimulatorWebInspectorPlistFrameCodec
    private let continuation: AsyncStream<Data>.Continuation
    private let descriptor: Int32

    init(descriptor: Int32, frameCodec: SimulatorWebInspectorPlistFrameCodec) {
        self.descriptor = descriptor
        self.frameCodec = frameCodec
        let pair = AsyncStream.makeStream(
            of: Data.self,
            bufferingPolicy: .bufferingOldest(Self.maximumBufferedBodyCount)
        )
        messages = pair.stream
        continuation = pair.continuation
        startReader()
    }

    deinit {
        Darwin.shutdown(descriptor, SHUT_RDWR)
        Darwin.close(descriptor)
    }

    @MainActor
    func send(propertyList: [String: Any]) throws {
        let frame = try frameCodec.frame(propertyList)
        do {
            try frame.withUnsafeBytes { raw in
                guard let baseAddress = raw.baseAddress else { return }
                let written = Darwin.send(
                    descriptor,
                    baseAddress,
                    raw.count,
                    MSG_DONTWAIT | MSG_NOSIGNAL
                )
                guard written == raw.count else {
                    throw SimulatorWebInspectorError.socketFailure(
                        written < 0 ? errno : EIO
                    )
                }
            }
        } catch {
            // A partial frame cannot be retried without corrupting the plist
            // stream. Closing also turns socket backpressure into a contained,
            // recoverable inspector failure instead of a MainActor stall.
            requestClose()
            throw error
        }
    }

    @MainActor
    func close() {
        requestClose()
    }

    private func startReader() {
        let thread = Thread { [weak self] in
            self?.readLoop()
        }
        thread.name = "cmux-simulator-web-inspector"
        thread.stackSize = 1 << 20
        thread.start()
    }

    private func readLoop() {
        while let header = readExactly(4) {
            let length: Int
            do {
                length = try frameCodec.bodyLength(header: header)
            } catch {
                break
            }
            guard let body = readExactly(length) else { break }
            switch continuation.yield(body) {
            case .enqueued:
                continue
            case .dropped, .terminated:
                requestClose()
                finishReader()
                return
            @unknown default:
                requestClose()
                finishReader()
                return
            }
        }
        finishReader()
    }

    private func readExactly(_ count: Int) -> Data? {
        guard count > 0 else { return Data() }
        var bytes = [UInt8](repeating: 0, count: count)
        var offset = 0
        while offset < count {
            let received = bytes.withUnsafeMutableBytes { raw -> Int in
                guard let baseAddress = raw.baseAddress else { return -1 }
                return Darwin.read(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    count - offset
                )
            }
            if received > 0 {
                offset += received
            } else if received == -1, errno == EINTR {
                continue
            } else {
                return nil
            }
        }
        return Data(bytes)
    }

    private nonisolated func requestClose() {
        Darwin.shutdown(descriptor, SHUT_RDWR)
        continuation.finish()
    }

    private nonisolated func finishReader() {
        Darwin.shutdown(descriptor, SHUT_RDWR)
        continuation.finish()
    }
}
