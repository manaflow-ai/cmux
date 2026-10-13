public import Foundation
import Darwin

/// An ordered, reliable byte stream over one end of a tunneled TCP
/// connection (a socketpair fd from libcmuxwg).
///
/// The fd is non-blocking; reads and writes wait for readiness on dispatch
/// sources, so no thread blocks. One read and any number of writes may be in
/// flight; writes complete in call order. `close()` fails pending calls and
/// releases the fd exactly once.
public final class SocketStream: @unchecked Sendable {
    public enum Failure: Error, Equatable, Sendable {
        case closed
        case system(Int32)
    }

    private let fd: Int32
    private let queue = DispatchQueue(label: "cmux.wireguard.socket")
    // Everything below is touched only on `queue`.
    private let readSource: any DispatchSourceRead
    private let writeSource: any DispatchSourceWrite
    private var readArmed = false
    private var writeArmed = false
    private var pendingRead: (maximum: Int, continuation: CheckedContinuation<Data?, any Error>)?
    private var pendingWrites: [(data: Data, offset: Int, continuation: CheckedContinuation<Void, any Error>)] = []
    private var closed = false
    private var sawEOF = false

    /// Takes ownership of `fd`.
    public init(fileDescriptor fd: Int32) {
        self.fd = fd
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        readSource = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        writeSource = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
        readSource.setEventHandler { [weak self] in self?.serviceRead() }
        writeSource.setEventHandler { [weak self] in self?.serviceWrites() }
        // The fd closes once both sources are cancelled, never while one is live.
        let group = DispatchGroup()
        group.enter()
        group.enter()
        readSource.setCancelHandler { group.leave() }
        writeSource.setCancelHandler { group.leave() }
        group.notify(queue: queue) { Darwin.close(fd) }
        // Sources start suspended; activate, then suspend until needed.
        readSource.activate()
        writeSource.activate()
        readSource.suspend()
        writeSource.suspend()
    }

    deinit {
        if !closed {
            if !readArmed { readSource.resume() }
            if !writeArmed { writeSource.resume() }
            readSource.cancel()
            writeSource.cancel()
        }
    }

    /// The next chunk of at most `maximumBytes`, or nil at end of stream.
    public func read(maximumBytes: Int = 64 * 1024) async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                guard !closed else { return continuation.resume(throwing: Failure.closed) }
                guard pendingRead == nil else {
                    return continuation.resume(throwing: Failure.system(EBUSY))
                }
                if sawEOF { return continuation.resume(returning: nil) }
                pendingRead = (maximumBytes, continuation)
                serviceRead()
            }
        }
    }

    /// Writes all of `data`, in order with earlier writes.
    public func write(_ data: Data) async throws {
        guard !data.isEmpty else { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            queue.async { [self] in
                guard !closed else { return continuation.resume(throwing: Failure.closed) }
                pendingWrites.append((data, 0, continuation))
                if pendingWrites.count == 1 { serviceWrites() }
            }
        }
    }

    /// Ends the write side; the peer reads end of stream. Reads continue.
    public func shutdownWrite() {
        queue.async { [self] in
            guard !closed else { return }
            Darwin.shutdown(fd, SHUT_WR)
        }
    }

    /// Closes both directions. Idempotent.
    public func close() {
        queue.async { [self] in
            guard !closed else { return }
            closed = true
            if let read = pendingRead {
                pendingRead = nil
                read.continuation.resume(throwing: Failure.closed)
            }
            for write in pendingWrites { write.continuation.resume(throwing: Failure.closed) }
            pendingWrites.removeAll()
            Darwin.shutdown(fd, SHUT_RDWR)
            if !readArmed { readSource.resume() }
            if !writeArmed { writeSource.resume() }
            readArmed = true
            writeArmed = true
            readSource.cancel()
            writeSource.cancel()
        }
    }

    private func serviceRead() {
        guard let pending = pendingRead else { return disarmRead() }
        var buffer = [UInt8](repeating: 0, count: max(1, pending.maximum))
        let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
        if count > 0 {
            pendingRead = nil
            disarmRead()
            pending.continuation.resume(returning: Data(buffer[0..<count]))
        } else if count == 0 {
            pendingRead = nil
            sawEOF = true
            disarmRead()
            pending.continuation.resume(returning: nil)
        } else if errno == EAGAIN || errno == EINTR {
            armRead()
        } else {
            let code = errno
            pendingRead = nil
            disarmRead()
            // A reset peer is the end of the stream, not a failure to report.
            if code == ECONNRESET || code == ENOTCONN {
                sawEOF = true
                pending.continuation.resume(returning: nil)
            } else {
                pending.continuation.resume(throwing: Failure.system(code))
            }
        }
    }

    private func serviceWrites() {
        while var head = pendingWrites.first {
            let remaining = head.data.count - head.offset
            let written = head.data.withUnsafeBytes { raw in
                Darwin.write(fd, raw.baseAddress!.advanced(by: head.offset), remaining)
            }
            if written > 0 {
                head.offset += written
                if head.offset == head.data.count {
                    pendingWrites.removeFirst()
                    head.continuation.resume()
                } else {
                    pendingWrites[0] = head
                }
            } else if written < 0, errno == EAGAIN || errno == EINTR {
                return armWrite()
            } else {
                let code = written < 0 ? errno : EPIPE
                for write in pendingWrites { write.continuation.resume(throwing: Failure.system(code)) }
                pendingWrites.removeAll()
                return disarmWrite()
            }
        }
        disarmWrite()
    }

    private func armRead() {
        guard !readArmed, !closed else { return }
        readArmed = true
        readSource.resume()
    }

    private func disarmRead() {
        guard readArmed, !closed else { return }
        readArmed = false
        readSource.suspend()
    }

    private func armWrite() {
        guard !writeArmed, !closed else { return }
        writeArmed = true
        writeSource.resume()
    }

    private func disarmWrite() {
        guard writeArmed, !closed else { return }
        writeArmed = false
        writeSource.suspend()
    }
}
