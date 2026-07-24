internal import Darwin
internal import Dispatch
public import Foundation

/// Raw authenticated reader for a cmuxd semantic-scene endpoint.
///
/// The endpoint is intentionally not newline framed. Its records can carry a
/// bounded 64-MiB Ghostty scene, and the caller incrementally decodes whatever
/// chunks `receive` returns.
public actor BackendTerminalSceneEndpointTransport {
    public enum TransportError: Error, Equatable, Sendable {
        case alreadyConnected
        case notConnected
        case invalidEndpointPath
        case invalidEndpointFile
        case invalidEndpointToken
        case peerIdentityMismatch
        case concurrentReceive
        case invalidReceiveLimit
    }

    private static let authenticationMagic = Data("CMXSCNA1".utf8)

    private let receipt: BackendTerminalSceneEndpointReceipt
    private let expectedPeer: BackendPeerIdentity
    private let eventQueue = DispatchQueue(
        label: "com.cmux.terminal-backend.scene-endpoint",
        qos: .userInteractive
    )
    private var fileDescriptor: Int32?
    private var readSource: (any DispatchSourceRead)?
    private var readWaiter: CheckedContinuation<Void, any Error>?
    private var writeSource: (any DispatchSourceWrite)?
    private var writeWaiter: CheckedContinuation<Void, any Error>?
    private var hasOpened = false
    private var connected = false
    private var receiveRunning = false

    public init(
        receipt: BackendTerminalSceneEndpointReceipt,
        expectedPeer: BackendPeerIdentity
    ) {
        self.receipt = receipt
        self.expectedPeer = expectedPeer
    }

    deinit {
        if let fileDescriptor {
            Darwin.shutdown(fileDescriptor, SHUT_RDWR)
            Darwin.close(fileDescriptor)
        }
    }

    /// Connects once, revalidates cmuxd's kernel identity, and writes the bearer proof.
    public func connect() async throws {
        guard !hasOpened else { throw TransportError.alreadyConnected }
        hasOpened = true
        let token = try decodedToken()
        try validateEndpointFile()

        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw posixError() }
        do {
            try configure(descriptor)
            fileDescriptor = descriptor
            var address = try unixAddress()
            let status = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(
                        descriptor,
                        $0,
                        socklen_t(MemoryLayout<sockaddr_un>.size)
                    )
                }
            }
            if status != 0 {
                guard errno == EINPROGRESS else { throw posixError() }
                try await waitUntilWritable()
                try verifyConnectResult(descriptor)
            }
            try Task.checkCancellation()
            guard fileDescriptor == descriptor else {
                throw BackendProtocolError.connectionClosed
            }
            guard try peerIdentity(descriptor) == expectedPeer else {
                throw TransportError.peerIdentityMismatch
            }
            connected = true
            var authentication = Self.authenticationMagic
            authentication.append(token)
            try await writeFully(authentication)
        } catch {
            closeSocket(with: error)
            throw error
        }
    }

    /// Returns the next nonempty byte chunk, or `nil` after orderly endpoint EOF.
    public func receive(maximumByteCount: Int = 64 * 1_024) async throws -> Data? {
        guard maximumByteCount > 0 else { throw TransportError.invalidReceiveLimit }
        guard connected else { throw TransportError.notConnected }
        guard !receiveRunning else { throw TransportError.concurrentReceive }
        receiveRunning = true
        defer { receiveRunning = false }

        while true {
            try Task.checkCancellation()
            guard connected, let descriptor = fileDescriptor else {
                throw BackendProtocolError.connectionClosed
            }
            var storage = [UInt8](repeating: 0, count: maximumByteCount)
            let count = storage.withUnsafeMutableBytes {
                Darwin.recv(descriptor, $0.baseAddress, $0.count, 0)
            }
            if count > 0 {
                return Data(storage.prefix(count))
            }
            if count == 0 {
                closeSocket(with: BackendProtocolError.connectionClosed)
                return nil
            }
            if errno == EAGAIN || errno == EWOULDBLOCK {
                try await waitUntilReadable()
            } else if errno != EINTR {
                let error = posixError()
                closeSocket(with: error)
                throw error
            }
        }
    }

    public func close() {
        closeSocket(with: CancellationError())
    }

    private func validateEndpointFile() throws {
        guard receipt.path.first == "/",
              receipt.path.utf8.count > 1,
              receipt.path.utf8.count < MemoryLayout.size(
                  ofValue: sockaddr_un().sun_path
              ) else {
            throw TransportError.invalidEndpointPath
        }
        var metadata = stat()
        guard lstat(receipt.path, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFSOCK,
              metadata.st_uid == geteuid(),
              metadata.st_nlink == 1,
              metadata.st_mode & 0o777 == 0o600 else {
            throw TransportError.invalidEndpointFile
        }
    }

    private func decodedToken() throws -> Data {
        var normalized = receipt.token.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        normalized.append(String(repeating: "=", count: (4 - normalized.count % 4) % 4))
        guard receipt.token.utf8.count == 43,
              let token = Data(base64Encoded: normalized),
              token.count == 32 else {
            throw TransportError.invalidEndpointToken
        }
        return token
    }

    private func configure(_ descriptor: Int32) throws {
        let descriptorFlags = fcntl(descriptor, F_GETFD)
        guard descriptorFlags >= 0,
              fcntl(descriptor, F_SETFD, descriptorFlags | FD_CLOEXEC) == 0 else {
            throw posixError()
        }
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0,
              fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
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
    }

    private func unixAddress() throws -> sockaddr_un {
        let bytes = Array(receipt.path.utf8)
        var address = sockaddr_un()
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard !bytes.isEmpty, bytes.count < capacity else {
            throw TransportError.invalidEndpointPath
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

    private func peerIdentity(_ descriptor: Int32) throws -> BackendPeerIdentity {
        var auditToken = audit_token_t()
        var auditTokenSize = socklen_t(MemoryLayout<audit_token_t>.size)
        guard getsockopt(
            descriptor,
            SOL_LOCAL,
            LOCAL_PEERTOKEN,
            &auditToken,
            &auditTokenSize
        ) == 0,
            auditTokenSize == MemoryLayout<audit_token_t>.size else {
            throw TransportError.peerIdentityMismatch
        }
        let auditProcessID = audit_token_to_pid(auditToken)
        let auditUserID = audit_token_to_euid(auditToken)
        guard auditProcessID > 0 else {
            throw TransportError.peerIdentityMismatch
        }

        var processID: pid_t = 0
        var processIDSize = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(
            descriptor,
            SOL_LOCAL,
            LOCAL_PEERPID,
            &processID,
            &processIDSize
        ) == 0,
            processIDSize == MemoryLayout<pid_t>.size,
            processID == auditProcessID else {
            throw TransportError.peerIdentityMismatch
        }

        var credentials = xucred()
        var credentialsSize = socklen_t(MemoryLayout<xucred>.size)
        guard getsockopt(
            descriptor,
            SOL_LOCAL,
            LOCAL_PEERCRED,
            &credentials,
            &credentialsSize
        ) == 0,
            credentialsSize == MemoryLayout<xucred>.size,
            credentials.cr_version == XUCRED_VERSION,
            credentials.cr_uid == auditUserID else {
            throw TransportError.peerIdentityMismatch
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
        receiveRunning = false
    }

    private func posixError(_ code: Int32 = errno) -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(code),
            userInfo: [NSFilePathErrorKey: receipt.path]
        )
    }
}
