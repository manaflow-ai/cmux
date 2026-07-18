internal import Darwin
internal import Dispatch
public import Foundation

/// Newline-delimited JSON over a private Unix domain socket.
///
/// This transport owns the POSIX socket directly so readiness checks can read
/// `LOCAL_PEERTOKEN`, `LOCAL_PEERPID`, and `LOCAL_PEERCRED` from the same
/// connection carrying the protocol handshake. Network.framework does not
/// expose that socket identity.
public actor UnixBackendTransport: BackendPeerIdentityTransport {
    /// The daemon's maximum size for one unframed client request.
    public static let defaultMaximumOutboundMessageBytes = 4 * 1_024 * 1_024

    /// The daemon's maximum retained size for one response or event frame.
    public static let defaultMaximumInboundMessageBytes = 16 * 1_024 * 1_024

    /// The maximum number of complete frames retained by the client writer.
    public static let defaultMaximumPendingWriteCount = 256

    /// The maximum aggregate bytes retained by the client writer.
    public static let defaultMaximumPendingWriteBytes = 16 * 1_024 * 1_024

    /// The legacy symmetric message limit.
    @available(*, deprecated, message: "Use the directional message limits")
    public static let defaultMaximumMessageBytes = 8 * 1_024 * 1_024

    private struct PendingWrite {
        let data: Data
        let continuation: CheckedContinuation<Void, any Error>
    }

    private let path: String
    private let maximumOutboundMessageBytes: Int
    private let maximumPendingWriteCount: Int
    private let maximumPendingWriteBytes: Int
    private let socketSendBufferBytes: Int?
    private let eventQueue: DispatchQueue
    private var fileDescriptor: Int32?
    private var hasOpened = false
    private var connected = false
    private var framer: BackendLineFramer
    private var readSource: (any DispatchSourceRead)?
    private var readWaiter: CheckedContinuation<Void, any Error>?
    private var writeSource: (any DispatchSourceWrite)?
    private var writeWaiter: CheckedContinuation<Void, any Error>?
    private var pendingWrites: [PendingWrite] = []
    private var pendingWriteBytes = 0
    private var writerRunning = false
    private var receiveRunning = false

    /// Creates a newline-framed Unix domain socket transport.
    ///
    /// - Parameters:
    ///   - path: The filesystem path of the backend Unix domain socket.
    ///   - maximumOutboundMessageBytes: The maximum unframed request size.
    ///   - maximumInboundMessageBytes: The maximum unframed response or event size.
    ///   - maximumPendingWriteCount: The maximum number of retained complete frames.
    ///   - maximumPendingWriteBytes: The maximum aggregate retained framed bytes.
    public init(
        path: String,
        maximumOutboundMessageBytes: Int = UnixBackendTransport.defaultMaximumOutboundMessageBytes,
        maximumInboundMessageBytes: Int = UnixBackendTransport.defaultMaximumInboundMessageBytes,
        maximumPendingWriteCount: Int = UnixBackendTransport.defaultMaximumPendingWriteCount,
        maximumPendingWriteBytes: Int = UnixBackendTransport.defaultMaximumPendingWriteBytes
    ) {
        precondition(maximumOutboundMessageBytes > 0)
        precondition(maximumInboundMessageBytes > 0)
        precondition(maximumPendingWriteCount > 0)
        precondition(maximumPendingWriteBytes > 0)
        self.path = path
        self.maximumOutboundMessageBytes = maximumOutboundMessageBytes
        self.maximumPendingWriteCount = maximumPendingWriteCount
        self.maximumPendingWriteBytes = maximumPendingWriteBytes
        socketSendBufferBytes = nil
        framer = BackendLineFramer(maximumMessageBytes: maximumInboundMessageBytes)
        eventQueue = DispatchQueue(
            label: "com.cmux.terminal-backend.unix-transport",
            qos: .userInteractive
        )
    }

    /// Creates a transport with the legacy symmetric message limit.
    @available(*, deprecated, message: "Use the directional message-limit initializer")
    public init(path: String, maximumMessageBytes: Int) {
        precondition(maximumMessageBytes > 0)
        self.path = path
        maximumOutboundMessageBytes = maximumMessageBytes
        maximumPendingWriteCount = Self.defaultMaximumPendingWriteCount
        maximumPendingWriteBytes = Self.defaultMaximumPendingWriteBytes
        socketSendBufferBytes = nil
        framer = BackendLineFramer(maximumMessageBytes: maximumMessageBytes)
        eventQueue = DispatchQueue(
            label: "com.cmux.terminal-backend.unix-transport",
            qos: .userInteractive
        )
    }

    init(
        path: String,
        maximumOutboundMessageBytes: Int,
        maximumInboundMessageBytes: Int,
        maximumPendingWriteCount: Int,
        maximumPendingWriteBytes: Int,
        socketSendBufferBytes: Int
    ) {
        precondition(maximumOutboundMessageBytes > 0)
        precondition(maximumInboundMessageBytes > 0)
        precondition(maximumPendingWriteCount > 0)
        precondition(maximumPendingWriteBytes > 0)
        precondition(socketSendBufferBytes > 0 && socketSendBufferBytes <= Int32.max)
        self.path = path
        self.maximumOutboundMessageBytes = maximumOutboundMessageBytes
        self.maximumPendingWriteCount = maximumPendingWriteCount
        self.maximumPendingWriteBytes = maximumPendingWriteBytes
        self.socketSendBufferBytes = socketSendBufferBytes
        framer = BackendLineFramer(maximumMessageBytes: maximumInboundMessageBytes)
        eventQueue = DispatchQueue(
            label: "com.cmux.terminal-backend.unix-transport",
            qos: .userInteractive
        )
    }

    deinit {
        if let fileDescriptor {
            Darwin.shutdown(fileDescriptor, SHUT_RDWR)
            Darwin.close(fileDescriptor)
        }
    }

    /// Opens the Unix domain socket and waits until the nonblocking connect completes.
    ///
    /// A transport instance is single-use. Create a new instance after closing
    /// so an old cancelled operation can never observe a recycled descriptor.
    ///
    /// - Throws: ``BackendProtocolError/alreadyConnected``, a POSIX socket
    ///   error, or cancellation while connecting.
    public func connect() async throws {
        guard !hasOpened else { throw BackendProtocolError.alreadyConnected }
        hasOpened = true

        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw posixError() }

        do {
            try configure(descriptor)
            fileDescriptor = descriptor
            var address = try unixAddress()
            let result = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(
                        descriptor,
                        $0,
                        socklen_t(MemoryLayout<sockaddr_un>.size)
                    )
                }
            }
            if result != 0 {
                guard errno == EINPROGRESS else { throw posixError() }
                try await waitUntilWritable()
                try verifyConnectResult(descriptor)
            }
            try Task.checkCancellation()
            guard fileDescriptor == descriptor else {
                throw BackendProtocolError.connectionClosed
            }
            connected = true
        } catch {
            if fileDescriptor == descriptor {
                closeSocket(with: error)
            } else {
                Darwin.close(descriptor)
            }
            throw error
        }
    }

    /// Returns the kernel credentials of the peer on this exact protocol socket.
    ///
    /// - Returns: The peer audit token, PID, and effective UID reported by macOS.
    /// - Throws: ``BackendProtocolError/notConnected``,
    ///   ``BackendProtocolError/peerIdentityMismatch``, or a POSIX credential error.
    public func peerIdentity() throws -> BackendPeerIdentity {
        guard connected, let descriptor = fileDescriptor else {
            throw BackendProtocolError.notConnected
        }

        var auditToken = audit_token_t()
        var auditTokenSize = socklen_t(MemoryLayout<audit_token_t>.size)
        guard getsockopt(
            descriptor,
            SOL_LOCAL,
            LOCAL_PEERTOKEN,
            &auditToken,
            &auditTokenSize
        ) == 0 else {
            throw posixError()
        }
        guard auditTokenSize == MemoryLayout<audit_token_t>.size else {
            throw BackendProtocolError.peerIdentityMismatch
        }

        let auditProcessID = audit_token_to_pid(auditToken)
        let auditUserID = audit_token_to_euid(auditToken)
        guard auditProcessID > 0 else {
            throw BackendProtocolError.peerIdentityMismatch
        }

        var processID: pid_t = 0
        var processIDSize = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(
            descriptor,
            SOL_LOCAL,
            LOCAL_PEERPID,
            &processID,
            &processIDSize
        ) == 0 else {
            throw posixError()
        }
        guard processIDSize == MemoryLayout<pid_t>.size,
              processID == auditProcessID else {
            throw BackendProtocolError.peerIdentityMismatch
        }

        var credentials = xucred()
        var credentialsSize = socklen_t(MemoryLayout<xucred>.size)
        guard getsockopt(
            descriptor,
            SOL_LOCAL,
            LOCAL_PEERCRED,
            &credentials,
            &credentialsSize
        ) == 0 else {
            throw posixError()
        }
        guard credentialsSize == MemoryLayout<xucred>.size,
              credentials.cr_version == XUCRED_VERSION,
              credentials.cr_uid == auditUserID else {
            throw BackendProtocolError.peerIdentityMismatch
        }

        return BackendPeerIdentity(
            processID: UInt32(auditProcessID),
            userID: UInt32(auditUserID),
            auditToken: BackendAuditToken(
                word0: auditToken.val.0,
                word1: auditToken.val.1,
                word2: auditToken.val.2,
                word3: auditToken.val.3,
                word4: auditToken.val.4,
                word5: auditToken.val.5,
                word6: auditToken.val.6,
                word7: auditToken.val.7
            )
        )
    }

    /// Sends one UTF-8 JSON message followed by a newline delimiter.
    ///
    /// Concurrent callers are serialized into complete frames so their bytes
    /// cannot interleave on the stream.
    ///
    /// - Parameter message: The unframed protocol message.
    /// - Throws: A connection, size, UTF-8, framing, or POSIX socket error.
    public func send(_ message: Data) async throws {
        try Task.checkCancellation()
        guard connected else { throw BackendProtocolError.notConnected }
        guard message.count <= maximumOutboundMessageBytes else {
            throw BackendProtocolError.oversizedMessage(limit: maximumOutboundMessageBytes)
        }
        guard String(data: message, encoding: .utf8) != nil,
              !message.contains(0x0A)
        else {
            throw BackendProtocolError.malformedMessage
        }

        var framed = message
        framed.append(0x0A)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                guard pendingWrites.count < maximumPendingWriteCount,
                      framed.count <= maximumPendingWriteBytes - pendingWriteBytes else {
                    continuation.resume(throwing: BackendProtocolError.writeQueueOverflow(
                        maximumMessages: maximumPendingWriteCount,
                        maximumBytes: maximumPendingWriteBytes
                    ))
                    return
                }
                pendingWrites.append(PendingWrite(data: framed, continuation: continuation))
                pendingWriteBytes += framed.count
                startWriterIfNeeded()
            }
        } onCancel: {
            Task { await self.cancelForAmbiguousWrite() }
        }
        try Task.checkCancellation()
    }

    /// Receives one newline-delimited protocol message.
    ///
    /// - Returns: The unframed message bytes.
    /// - Throws: A connection, size, framing, or POSIX socket error.
    public func receive() async throws -> Data {
        guard connected else { throw BackendProtocolError.notConnected }
        guard !receiveRunning else { throw BackendProtocolError.malformedMessage }
        receiveRunning = true
        defer { receiveRunning = false }

        while true {
            try Task.checkCancellation()
            guard connected, let descriptor = fileDescriptor else {
                throw BackendProtocolError.connectionClosed
            }
            if let message = try framer.nextMessage() {
                return message
            }

            var storage = [UInt8](
                repeating: 0,
                count: min(framer.maximumMessageBytes, 64 * 1_024)
            )
            let count = storage.withUnsafeMutableBytes {
                Darwin.recv(descriptor, $0.baseAddress, $0.count, 0)
            }
            if count > 0 {
                try framer.append(Data(storage.prefix(count)))
            } else if count == 0 {
                throw BackendProtocolError.connectionClosed
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                try await waitUntilReadable()
            } else if errno != EINTR {
                throw posixError()
            }
        }
    }

    /// Closes the socket and resumes every outstanding operation with cancellation.
    public func close() {
        closeSocket(with: CancellationError())
    }

    func pendingWriteMetrics() -> (count: Int, bytes: Int) {
        (pendingWrites.count, pendingWriteBytes)
    }

    private func configure(_ descriptor: Int32) throws {
        let descriptorFlags = fcntl(descriptor, F_GETFD)
        guard descriptorFlags >= 0,
              fcntl(descriptor, F_SETFD, descriptorFlags | FD_CLOEXEC) == 0 else {
            throw posixError()
        }

        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw posixError()
        }
        var enabled: Int32 = 1
        guard setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &enabled,
            socklen_t(MemoryLayout<Int32>.size)
        ) == 0 else {
            throw posixError()
        }
        if let configuredSendBufferBytes = socketSendBufferBytes {
            var sendBufferBytes = Int32(configuredSendBufferBytes)
            guard setsockopt(
                descriptor,
                SOL_SOCKET,
                SO_SNDBUF,
                &sendBufferBytes,
                socklen_t(MemoryLayout<Int32>.size)
            ) == 0 else {
                throw posixError()
            }
        }
    }

    private func unixAddress() throws -> sockaddr_un {
        let bytes = Array(path.utf8)
        var address = sockaddr_un()
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard !bytes.isEmpty, bytes.count < capacity else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(ENAMETOOLONG),
                userInfo: [NSFilePathErrorKey: path]
            )
        }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.copyBytes(from: bytes)
            destination[bytes.count] = 0
        }
        return address
    }

    private func verifyConnectResult(_ descriptor: Int32) throws {
        var socketError: Int32 = 0
        var socketErrorSize = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(
            descriptor,
            SOL_SOCKET,
            SO_ERROR,
            &socketError,
            &socketErrorSize
        ) == 0 else {
            throw posixError()
        }
        guard socketError == 0 else { throw posixError(socketError) }
    }

    private func startWriterIfNeeded() {
        guard !writerRunning else { return }
        writerRunning = true
        Task { await drainWrites() }
    }

    private func drainWrites() async {
        while connected, !pendingWrites.isEmpty {
            let pending = pendingWrites[0]
            do {
                try await writeFully(pending.data)
                guard connected, !pendingWrites.isEmpty else { return }
                let completed = pendingWrites.removeFirst()
                pendingWriteBytes -= completed.data.count
                completed.continuation.resume()
            } catch {
                closeSocket(with: error)
                return
            }
        }
        writerRunning = false
    }

    private func writeFully(_ data: Data) async throws {
        var offset = 0
        while offset < data.count {
            try Task.checkCancellation()
            guard connected, let descriptor = fileDescriptor else {
                throw BackendProtocolError.connectionClosed
            }
            let count = data.withUnsafeBytes { bytes in
                Darwin.send(
                    descriptor,
                    bytes.baseAddress?.advanced(by: offset),
                    bytes.count - offset,
                    0
                )
            }
            if count > 0 {
                offset += count
            } else if count < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                try await waitUntilWritable()
            } else if count < 0, errno == EINTR {
                continue
            } else {
                throw count == 0 ? BackendProtocolError.connectionClosed : posixError()
            }
        }
    }

    private func waitUntilReadable() async throws {
        guard readWaiter == nil, let descriptor = fileDescriptor else {
            throw BackendProtocolError.connectionClosed
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let source = DispatchSource.makeReadSource(
                    fileDescriptor: descriptor,
                    queue: eventQueue
                )
                readSource = source
                readWaiter = continuation
                source.setEventHandler { [weak self] in
                    Task { await self?.finishReadWait() }
                }
                source.resume()
            }
        } onCancel: {
            Task { await self.cancelReadWait() }
        }
    }

    private func waitUntilWritable() async throws {
        guard writeWaiter == nil, let descriptor = fileDescriptor else {
            throw BackendProtocolError.connectionClosed
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let source = DispatchSource.makeWriteSource(
                    fileDescriptor: descriptor,
                    queue: eventQueue
                )
                writeSource = source
                writeWaiter = continuation
                source.setEventHandler { [weak self] in
                    Task { await self?.finishWriteWait() }
                }
                source.resume()
            }
        } onCancel: {
            Task { await self.cancelWriteWait() }
        }
    }

    private func finishReadWait() {
        readSource?.cancel()
        readSource = nil
        readWaiter?.resume()
        readWaiter = nil
    }

    private func finishWriteWait() {
        writeSource?.cancel()
        writeSource = nil
        writeWaiter?.resume()
        writeWaiter = nil
    }

    private func cancelReadWait() {
        guard let readWaiter else { return }
        readSource?.cancel()
        readSource = nil
        self.readWaiter = nil
        readWaiter.resume(throwing: CancellationError())
    }

    private func cancelWriteWait() {
        guard let writeWaiter else { return }
        writeSource?.cancel()
        writeSource = nil
        self.writeWaiter = nil
        writeWaiter.resume(throwing: CancellationError())
    }

    private func cancelForAmbiguousWrite() {
        closeSocket(with: CancellationError())
    }

    private func closeSocket(with error: any Error) {
        connected = false
        if let descriptor = fileDescriptor {
            Darwin.shutdown(descriptor, SHUT_RDWR)
            Darwin.close(descriptor)
            fileDescriptor = nil
        }
        readSource?.cancel()
        readSource = nil
        readWaiter?.resume(throwing: error)
        readWaiter = nil
        writeSource?.cancel()
        writeSource = nil
        writeWaiter?.resume(throwing: error)
        writeWaiter = nil
        for pending in pendingWrites {
            pending.continuation.resume(throwing: error)
        }
        pendingWrites.removeAll()
        pendingWriteBytes = 0
        writerRunning = false
        receiveRunning = false
        framer.reset()
    }

    private func posixError(_ code: Int32 = errno) -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(code),
            userInfo: [NSFilePathErrorKey: path]
        )
    }
}
