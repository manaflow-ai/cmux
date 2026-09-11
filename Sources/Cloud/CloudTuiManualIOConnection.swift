import Darwin
import Foundation

/// A long-lived JSON-lines connection to one local cmux-tui session socket.
///
/// The connection is a transport primitive: it forwards commands and publishes
/// decoded attach frames. Socket I/O and JSON/base64 decoding are confined to a
/// utility queue so Ghostty's main actor and input path never wait on a file
/// descriptor or parse a large output burst.
// @unchecked Sendable is safe here because every mutable descriptor/source/
// framing field and pending demand are accessed only on `queue`. Continuations
// hand immutable frames back to the single async consumer.
final class CloudTuiManualIOConnection: @unchecked Sendable {
    private static let maximumLineBytes = 16 * 1024 * 1024
    private static let readChunkBytes = 16 * 1024

    private let socketPath: String
    private let queue: DispatchQueue
    private let commandBuilder: CloudTuiManualIOCommand

    /// Single-consumer stream. Each next() requests one frame, so a busy renderer
    /// applies socket backpressure instead of overflowing a decoded-frame queue.
    var events: AsyncStream<CloudTuiManualIOFrame> {
        AsyncStream(unfolding: { [weak self] in
            await self?.nextFrame()
        }, onCancel: { [weak self] in
            self?.close()
        })
    }

    private var nextFrameContinuation: CheckedContinuation<CloudTuiManualIOFrame?, Never>?
    private var descriptor: Int32 = -1
    private var isConnected = false
    private var readSource: DispatchSourceRead?
    private var readSourceSuspended = false
    private var writeSource: DispatchSourceWrite?
    private var writeSourceSuspended = true
    private var descriptorLease: CloudTuiManualIODescriptorLease?
    private var startContinuation: CheckedContinuation<Void, Error>?
    private var pendingLine = Data()
    private var pendingLineSearchOffset = 0
    // This storage is queue-owned and reused for every socket read.
    private var readBuffer = [UInt8](repeating: 0, count: CloudTuiManualIOConnection.readChunkBytes)
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
        ),
        commandBuilder: CloudTuiManualIOCommand = CloudTuiManualIOCommand()
    ) {
        self.socketPath = socketPath
        self.queue = queue
        self.commandBuilder = commandBuilder
    }

    private func nextFrame() async -> CloudTuiManualIOFrame? {
        guard !Task.isCancelled else {
            close()
            return nil
        }
        return await withCheckedContinuation { continuation in
            queue.async { [self] in
                guard !closed, nextFrameContinuation == nil else {
                    continuation.resume(returning: nil)
                    return
                }
                nextFrameContinuation = continuation
                resumeReadSourceLocked()
                // A previous read may already contain the next complete line;
                // do not depend on another socket-readability notification.
                readAvailableLocked()
            }
        }
    }

    /// Connects to the local link socket and starts line delivery.
    func start() async throws {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                queue.async { [self] in
                    guard !closed else {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    if descriptor >= 0 {
                        if isConnected {
                            continuation.resume()
                        } else {
                            continuation.resume(throwing: Self.socketError("start", code: EALREADY))
                        }
                        return
                    }
                    startContinuation = continuation
                    do {
                        try openLocked()
                    } catch {
                        // `closeLocked` must not also resume this continuation;
                        // the catch owns the one terminal resume for setup errors.
                        startContinuation = nil
                        closeLocked()
                        continuation.resume(throwing: error)
                    }
                }
            }
        }, onCancel: { [weak self] in
            self?.close()
        })
    }

    /// Enqueues one JSON command. Commands are serialized with incoming lines.
    func send(_ command: [String: Any]) {
        guard let line = commandBuilder.line(command) else { return }
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

        let flags = fcntl(fd, F_GETFL, 0)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw Self.socketError("nonblocking")
        }

        let descriptorLease = CloudTuiManualIODescriptorLease(descriptor: fd)
        self.descriptorLease = descriptorLease
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        descriptorLease.registerSource()
        source.setEventHandler { [weak self] in
            self?.readAvailableLocked()
        }
        source.setCancelHandler {
            descriptorLease.sourceDidCancel()
        }
        readSource = source

        let writeSource = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
        descriptorLease.registerSource()
        writeSource.setEventHandler { [weak self] in
            self?.finishConnectLocked()
        }
        writeSource.setCancelHandler {
            descriptorLease.sourceDidCancel()
        }
        self.writeSource = writeSource
        writeSourceSuspended = false

        // Activate both sources before any fallible setup below. If address
        // construction fails, their cancellation handlers still own the
        // descriptor and close it exactly once.
        source.activate()
        writeSource.activate()
        if nextFrameContinuation == nil {
            suspendReadSourceLocked()
        }

        var address = try Self.unixAddress(path: socketPath)
        let addressLength = socklen_t(Self.unixAddressLength(address: address))
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, addressLength)
            }
        }
        guard connected == 0 else {
            guard errno == EINPROGRESS else { throw Self.socketError("connect") }
            return
        }
        finishConnectLocked()
    }

    /// Completes the nonblocking Unix-domain connect and switches the write
    /// source from connection readiness to queued-command flushing.
    private func finishConnectLocked() {
        guard !closed, descriptor >= 0 else { return }
        if isConnected {
            flushWritesLocked()
            return
        }
        var socketError: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &socketError, &length) == 0 else {
            failStartLocked(Self.socketError("connect status"))
            return
        }
        guard socketError == 0 else {
            failStartLocked(Self.socketError("connect", code: socketError))
            return
        }
        isConnected = true
        writeSource?.setEventHandler { [weak self] in
            self?.flushWritesLocked()
        }
        if pendingWrites.isEmpty {
            suspendWriteSourceLocked()
        } else {
            flushWritesLocked()
        }
        let continuation = startContinuation
        startContinuation = nil
        continuation?.resume()
        readAvailableLocked()
    }

    private func failStartLocked(_ error: Error) {
        let continuation = startContinuation
        startContinuation = nil
        closeLocked()
        continuation?.resume(throwing: error)
    }

    private func readAvailableLocked() {
        guard !closed, isConnected, descriptor >= 0, nextFrameContinuation != nil else { return }
        while !closed {
            while let newline = pendingLine[
                pendingLine.index(pendingLine.startIndex, offsetBy: pendingLineSearchOffset)...
            ].firstIndex(of: 0x0A) {
                guard pendingLine.distance(from: pendingLine.startIndex, to: newline) <= Self.maximumLineBytes else {
                    closeLocked()
                    return
                }
                let line = Data(pendingLine[..<newline])
                pendingLine.removeSubrange(...newline)
                pendingLineSearchOffset = 0
                guard !line.isEmpty,
                      let frame = CloudTuiManualIOFrameDecoder().decode(line) else { continue }
                let continuation = nextFrameContinuation
                nextFrameContinuation = nil
                suspendReadSourceLocked()
                continuation?.resume(returning: frame)
                return
            }
            // Only newly read bytes need scanning while a large line arrives.
            pendingLineSearchOffset = pendingLine.count
            // Retain at most one protocol-sized unfinished line plus one read
            // chunk. Complete frames stay in the socket until next() requests
            // them; kernel/link backpressure bounds a stalled consumer's memory.
            guard pendingLine.count <= Self.maximumLineBytes else {
                closeLocked()
                return
            }
            let count = readBuffer.withUnsafeMutableBytes { buffer in
                Darwin.read(descriptor, buffer.baseAddress, buffer.count)
            }
            if count > 0 {
                pendingLine.append(readBuffer, count: count)
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

    private func resumeReadSourceLocked() {
        guard readSourceSuspended, let readSource else { return }
        readSourceSuspended = false
        readSource.resume()
    }

    private func suspendReadSourceLocked() {
        guard !readSourceSuspended, let readSource else { return }
        readSourceSuspended = true
        readSource.suspend()
    }

    private func flushWritesLocked() {
        guard !closed, isConnected, descriptor >= 0 else { return }
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
        isConnected = false
        pendingLine.removeAll(keepingCapacity: false)
        pendingLineSearchOffset = 0
        pendingWrites.removeAll(keepingCapacity: false)
        pendingWriteOffset = 0
        pendingWriteBytes = 0
        let descriptorToClose = self.descriptor
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
        if readSourceSuspended {
            readSourceSuspended = false
            source?.resume()
        }
        readSource = nil
        self.descriptor = -1
        source?.cancel()
        if source == nil, writeSource == nil {
            if let descriptorLease {
                descriptorLease.closeIfReady()
            } else if descriptorToClose >= 0 {
                Darwin.close(descriptorToClose)
            }
        }
        let continuation = startContinuation
        startContinuation = nil
        let frameContinuation = nextFrameContinuation
        nextFrameContinuation = nil
        frameContinuation?.resume(returning: nil)
        continuation?.resume(throwing: CancellationError())
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

    private static func socketError(_ operation: String, code: Int32 = errno) -> NSError {
        NSError(
            domain: "cmux.cloud.manual-io",
            code: Int(code),
            userInfo: [
                NSLocalizedDescriptionKey: "Cloud terminal socket " + operation + " failed: " + String(cString: strerror(code))
            ]
        )
    }
}
