import Darwin
import Foundation

/// A long-lived JSON-lines connection to one local cmux-tui session socket.
///
/// The connection is a transport primitive: it forwards commands and publishes
/// decoded attach frames. Socket I/O and JSON/base64 decoding are confined to a
/// utility queue so Ghostty's main actor and input path never wait on a file
/// descriptor or parse a large output burst.
// @unchecked Sendable is safe here because every mutable descriptor/source/
// framing field is accessed only on `queue`; the AsyncStream continuation is
// the sole cross-thread handoff and carries immutable `Data` values.
final class CloudTuiManualIOConnection: @unchecked Sendable {
    private static let maximumLineBytes = 16 * 1024 * 1024

    private let socketPath: String
    private let queue: DispatchQueue
    let events: AsyncStream<CloudTuiManualIOFrame>
    private let eventsContinuation: AsyncStream<CloudTuiManualIOFrame>.Continuation
    private var descriptor: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var writeSource: DispatchSourceWrite?
    private var writeSourceSuspended = true
    private var pendingLine = Data()
    private var pendingWrites: [Data] = []
    private var pendingWriteOffset = 0
    private var pendingWriteBytes = 0
    private let pendingWriteByteLimit = 256 * 1024
    private var closed = false

    init(
        socketPath: String,
        queue: DispatchQueue = DispatchQueue(
            label: "com.cmux.cloud-manual-io",
            qos: .userInitiated
        )
    ) {
        self.socketPath = socketPath
        self.queue = queue
        // A stalled Ghostty parser must not let a remote output burst grow an
        // unbounded in-memory queue. Dropping a frame would corrupt the VT
        // stream, so the bounded overflow edge closes this attachment and lets
        // the owner reconnect from a fresh snapshot.
        (events, eventsContinuation) = AsyncStream<CloudTuiManualIOFrame>.makeStream(
            bufferingPolicy: .bufferingOldest(2_048)
        )
        eventsContinuation.onTermination = { [weak self] _ in
            self?.close()
        }
    }

    /// Connects to the local link socket and starts line delivery.
    func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                guard !closed else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                do {
                    try openLocked()
                    continuation.resume()
                } catch {
                    closeLocked()
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Enqueues one JSON command. Commands are serialized with incoming lines.
    func send(_ command: [String: Any]) {
        guard let line = CloudTuiManualIOCommand.line(command) else { return }
        send(line: line)
    }

    /// Enqueues an already framed JSON line. Used by the input router so it can
    /// preserve ordering while a connection is being rebound.
    func send(line: Data) {
        queue.async { [self, line] in
            guard !closed, descriptor >= 0 else { return }
            guard pendingWriteBytes + line.count <= pendingWriteByteLimit else {
                // Commands are small and ordered. If a peer stops accepting
                // them for long enough to exhaust this bound, dropping one
                // command would be worse than restarting the attachment with
                // a fresh replay, so close and let the owner reconnect.
                closeLocked()
                return
            }
            pendingWrites.append(line)
            pendingWriteBytes += line.count
            flushWritesLocked()
        }
    }

    /// Closes only this attachment connection. The remote terminal session stays
    /// owned by cmux-tui and can be attached again later.
    func close() {
        queue.async { [self] in
            closeLocked()
        }
    }

    private func openLocked() throws {
        guard descriptor < 0 else { return }
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Self.socketError("create") }
        descriptor = fd
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var noSignal: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))

        do {
            var address = try Self.unixAddress(path: socketPath)
            let addressLength = socklen_t(Self.unixAddressLength(address: address))
            let connected = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fd, $0, addressLength)
                }
            }
            guard connected == 0 else { throw Self.socketError("connect") }
            let flags = fcntl(fd, F_GETFL, 0)
            if flags >= 0 { _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK) }
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in
                self?.readAvailableLocked()
            }
            source.setCancelHandler {
                Darwin.close(fd)
            }
            readSource = source
            let writeSource = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
            writeSource.setEventHandler { [weak self] in
                self?.flushWritesLocked()
            }
            // Keep the write source suspended until a non-blocking write
            // actually needs another readiness notification. An always-active
            // write source would wake the queue continuously while idle.
            self.writeSource = writeSource
            source.activate()
            writeSource.activate()
            writeSource.suspend()
            self.writeSourceSuspended = true
        } catch {
            descriptor = -1
            Darwin.close(fd)
            throw error
        }
    }

    private func readAvailableLocked() {
        guard !closed, descriptor >= 0 else { return }
        var bytes = [UInt8](repeating: 0, count: 16 * 1024)
        while !closed {
            let count = Darwin.read(descriptor, &bytes, bytes.count)
            if count > 0 {
                pendingLine.append(bytes, count: count)
                guard pendingLine.count <= Self.maximumLineBytes else {
                    closeLocked()
                    return
                }
                while let newline = pendingLine.firstIndex(of: 0x0A) {
                    let line = Data(pendingLine[..<newline])
                    pendingLine.removeSubrange(...newline)
                    if !line.isEmpty {
                        guard let frame = CloudTuiManualIOFrameDecoder().decode(line) else {
                            continue
                        }
                        switch eventsContinuation.yield(frame) {
                        case .enqueued:
                            break
                        case .dropped, .terminated:
                            closeLocked()
                            return
                        @unknown default:
                            closeLocked()
                            return
                        }
                    }
                }
                continue
            }
            if count == 0 {
                closeLocked()
                return
            }
            if errno == EINTR { continue }
            if errno == EAGAIN || errno == EWOULDBLOCK { return }
            closeLocked()
            return
        }
    }

    private func flushWritesLocked() {
        guard !closed, descriptor >= 0 else { return }
        while let first = pendingWrites.first, !closed {
            let remaining = first.count - pendingWriteOffset
            guard remaining > 0 else {
                pendingWrites.removeFirst()
                pendingWriteOffset = 0
                continue
            }
            let result: Int = first.withUnsafeBytes { rawBuffer in
                guard let base = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return Darwin.write(
                    descriptor,
                    base.advanced(by: pendingWriteOffset),
                    remaining
                )
            }
            if result > 0 {
                pendingWriteOffset += result
                pendingWriteBytes -= result
                if pendingWriteOffset == first.count {
                    pendingWrites.removeFirst()
                    pendingWriteOffset = 0
                }
                continue
            }
            if result < 0, errno == EINTR { continue }
            if result < 0, (errno == EAGAIN || errno == EWOULDBLOCK) {
                resumeWriteSourceLocked()
                return
            }
            closeLocked()
            return
        }
        suspendWriteSourceLocked()
    }

    private func resumeWriteSourceLocked() {
        guard writeSourceSuspended, let writeSource else { return }
        writeSourceSuspended = false
        writeSource.resume()
    }

    private func suspendWriteSourceLocked() {
        guard !writeSourceSuspended, let writeSource else { return }
        writeSourceSuspended = true
        writeSource.suspend()
    }

    private func closeLocked() {
        guard !closed else { return }
        closed = true
        pendingLine.removeAll(keepingCapacity: false)
        pendingWrites.removeAll(keepingCapacity: false)
        pendingWriteOffset = 0
        pendingWriteBytes = 0
        let writeSource = self.writeSource
        self.writeSource = nil
        if writeSourceSuspended {
            // A suspended dispatch source must be resumed before cancellation;
            // otherwise libdispatch retains the source forever.
            writeSourceSuspended = false
            writeSource?.resume()
        }
        writeSource?.cancel()
        let source = readSource
        readSource = nil
        descriptor = -1
        source?.cancel()
        eventsContinuation.finish()
    }

    private static func unixAddress(path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8CString)
        guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw socketError("path")
        }
        let offset = MemoryLayout<sockaddr_un>.offset(of: \.sun_path) ?? 0
        withUnsafeMutableBytes(of: &address) { rawBuffer in
            let destination = rawBuffer.baseAddress!.advanced(by: offset)
            pathBytes.withUnsafeBytes { source in
                destination.copyMemory(from: source.baseAddress!, byteCount: pathBytes.count)
            }
        }
        return address
    }

    private static func unixAddressLength(address: sockaddr_un) -> Int {
        let offset = MemoryLayout<sockaddr_un>.offset(of: \.sun_path) ?? 0
        let pathLength = withUnsafeBytes(of: address) { bytes in
            let path = bytes.dropFirst(offset)
            return path.firstIndex(of: 0).map { $0 - path.startIndex } ?? path.count
        }
        return offset + pathLength + 1
    }

    private static func socketError(_ operation: String) -> NSError {
        NSError(
            domain: "cmux.cloud.manual-io",
            code: Int(errno),
            userInfo: [
                NSLocalizedDescriptionKey: "Cloud terminal socket " + operation + " failed: " + String(cString: strerror(errno))
            ]
        )
    }
}
