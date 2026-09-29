import Foundation
import CmuxNextSettings
import Darwin
import Synchronization

/// One accepted client. Reads with a dispatch source on a private serial
/// queue, splits lines, and hands them to a single consumer task; writes are
/// queued on the same queue so responses keep request order.
final class ControlConnection: @unchecked Sendable {
    private let descriptor: Int32
    private let maxLineBytes: Int
    private let queue = DispatchQueue(label: "com.cmuxterm.next.control.connection")
    // Queue-confined.
    private var source: (any DispatchSourceRead)?
    private var buffer = Data()
    private var continuation: AsyncStream<String>.Continuation?
    private var consumer: Task<Void, Never>?
    private var isClosed = false
    private var isReadSuspended = false

    init(descriptor: Int32, maxLineBytes: Int) {
        self.descriptor = descriptor
        self.maxLineBytes = maxLineBytes
    }

    func start(consume: @escaping @Sendable (AsyncStream<String>) async -> Void) {
        let (stream, continuation) = AsyncStream<String>.makeStream(bufferingPolicy: .unbounded)
        queue.async { [self] in
            self.continuation = continuation
            let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
            source.setEventHandler { [weak self] in self?.readAvailable() }
            source.setCancelHandler { [descriptor] in Darwin.close(descriptor) }
            self.source = source
            source.resume()
            consumer = Task { await consume(stream) }
        }
    }

    func send(_ line: String) {
        let data = Data((line + "\n").utf8)
        queue.async { [self] in
            guard !isClosed else { return }
            writeAll(data)
        }
    }

    func close() {
        queue.async { [self] in
            guard !isClosed else { return }
            isClosed = true
            continuation?.finish()
            continuation = nil
            // A suspended source must be resumed before it can be cancelled.
            if isReadSuspended { source?.resume() }
            source?.cancel()
            source = nil
        }
    }

    // MARK: - Queue-confined

    private func readAvailable() {
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = read(descriptor, &chunk, chunk.count)
            if count > 0 {
                buffer.append(chunk, count: count)
                emitLines()
                if buffer.count > maxLineBytes {
                    writeAll(Data((ControlRouter.encode(id: nil, error: ControlError(code: "request_too_large", message: "Request line exceeds \(maxLineBytes) bytes")) + "\n").utf8))
                    finishInput()
                    return
                }
                continue
            }
            if count < 0, errno == EINTR { continue }
            if count < 0, errno == EAGAIN || errno == EWOULDBLOCK { return }
            // EOF or error: let the consumer drain what it has, then close.
            finishInput()
            return
        }
    }

    private func emitLines() {
        while let newline = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            continuation?.yield(String(decoding: lineData, as: UTF8.self))
        }
    }

    /// Stops reading (EOF, error, or oversized line) but keeps the
    /// descriptor open so queued responses still reach a half-closed client.
    private func finishInput() {
        continuation?.finish()
        continuation = nil
        if let source, !isReadSuspended {
            source.suspend()
            isReadSuspended = true
        }
    }

    private func writeAll(_ data: Data) {
        data.withUnsafeBytes { raw in
            guard var pointer = raw.baseAddress else { return }
            var remaining = raw.count
            while remaining > 0 {
                let written = write(descriptor, pointer, remaining)
                if written > 0 {
                    pointer += written
                    remaining -= written
                } else if written < 0, errno == EINTR {
                    continue
                } else if written < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                    var descriptorSet = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
                    // Bounded wait for a slow reader; a stuck client is dropped.
                    guard poll(&descriptorSet, 1, 5_000) > 0 else { return }
                } else {
                    return
                }
            }
        }
    }
}
