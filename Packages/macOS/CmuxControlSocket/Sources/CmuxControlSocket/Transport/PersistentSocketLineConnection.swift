public import Foundation
internal import Darwin

/// A serialized, reusable client connection for newline-delimited Unix-socket
/// commands.
///
/// The connection validates the kernel-reported peer before every write. It
/// never retries a command after an I/O failure because the server may already
/// have performed the side effect before the response was lost.
public final class PersistentSocketLineConnection: @unchecked Sendable {
    private struct State {
        let socket: Int32
        let path: String
        let timeout: TimeInterval
        let peerProcessID: pid_t?
        var responseBuffer = Data()
    }

    private let transport: SocketTransport
    private let maximumResponseByteCount: Int
    private let lock = NSLock()
    private var state: State?

    /// Creates a persistent line-oriented connection.
    ///
    /// - Parameters:
    ///   - transport: Socket syscall helpers.
    ///   - maximumResponseByteCount: Maximum buffered response size before the
    ///     connection fails closed.
    public init(
        transport: SocketTransport = SocketTransport(),
        maximumResponseByteCount: Int = 1_048_576
    ) {
        precondition(maximumResponseByteCount > 0)
        self.transport = transport
        self.maximumResponseByteCount = maximumResponseByteCount
    }

    deinit {
        lock.lock()
        closeConnection()
        lock.unlock()
    }

    /// Sends one command and reads its corresponding response line.
    ///
    /// Calls are serialized, so one connection can safely serve concurrent
    /// callers while preserving request/response order.
    public func command(
        _ command: String,
        at socketPath: String,
        timeout: TimeInterval,
        validatingPeer: @Sendable (pid_t?) -> Bool = { _ in true }
    ) -> (response: String, peerProcessID: pid_t?)? {
        guard !command.contains("\n"), !command.contains("\r") else {
            return nil
        }
        lock.lock()
        defer { lock.unlock() }

        guard ensureConnection(
            at: socketPath,
            timeout: timeout,
            validatingPeer: validatingPeer
        ), var current = state else {
            return nil
        }
        guard validatingPeer(current.peerProcessID) else {
            closeConnection()
            return nil
        }
        guard transport.writeAll(
            Data((command + "\n").utf8),
            to: current.socket
        ), let response = readResponseLine(from: &current) else {
            Darwin.close(current.socket)
            state = nil
            return nil
        }
        state = current
        return (
            response: response,
            peerProcessID: current.peerProcessID
        )
    }

    /// Closes the cached connection. The next command reconnects and
    /// revalidates the peer.
    public func invalidate() {
        lock.lock()
        closeConnection()
        lock.unlock()
    }

    private func ensureConnection(
        at socketPath: String,
        timeout: TimeInterval,
        validatingPeer: @Sendable (pid_t?) -> Bool
    ) -> Bool {
        if let current = state {
            if
                current.path == socketPath,
                current.timeout == timeout,
                validatingPeer(current.peerProcessID)
            {
                return true
            }
            closeConnection()
        }

        guard let connected = connect(
            to: socketPath,
            timeout: timeout,
            validatingPeer: validatingPeer
        ) else {
            return false
        }
        state = connected
        return true
    }

    private func connect(
        to socketPath: String,
        timeout: TimeInterval,
        validatingPeer: @Sendable (pid_t?) -> Bool
    ) -> State? {
        let socket = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard socket >= 0 else { return nil }
        var shouldClose = true
        defer {
            if shouldClose {
                Darwin.close(socket)
            }
        }
        guard
            transport.configureCloseOnExec(socket) == nil,
            transport.configureNoSigPipe(socket) == nil
        else {
            return nil
        }
        transport.configureSocketTimeouts(socket, timeout: timeout)

        var address = sockaddr_un()
        memset(&address, 0, MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8CString)
        let maximumLength = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count <= maximumLength else { return nil }
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            let buffer = UnsafeMutableRawPointer(pointer)
                .assumingMemoryBound(to: CChar.self)
            for index in pathBytes.indices {
                buffer[index] = pathBytes[index]
            }
        }
        let pathOffset =
            MemoryLayout<sockaddr_un>.offset(of: \.sun_path) ?? 0
        let addressLength = socklen_t(pathOffset + pathBytes.count)
#if os(macOS)
        address.sun_len = UInt8(min(Int(addressLength), 255))
#endif
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(
                to: sockaddr.self,
                capacity: 1
            ) { socketAddress in
                Darwin.connect(socket, socketAddress, addressLength)
            }
        }
        guard result == 0 else { return nil }
        let peerProcessID = transport.peerProcessID(of: socket)
        guard validatingPeer(peerProcessID) else { return nil }

        shouldClose = false
        return State(
            socket: socket,
            path: socketPath,
            timeout: timeout,
            peerProcessID: peerProcessID
        )
    }

    private func readResponseLine(from state: inout State) -> String? {
        while true {
            if let newline = state.responseBuffer.firstIndex(of: 0x0A) {
                let line = state.responseBuffer[..<newline]
                state.responseBuffer.removeSubrange(
                    state.responseBuffer.startIndex ... newline
                )
                return String(data: line, encoding: .utf8)
            }
            var bytes = [UInt8](repeating: 0, count: 4_096)
            let count = Darwin.read(
                state.socket,
                &bytes,
                bytes.count
            )
            if count < 0, errno == EINTR {
                continue
            }
            guard count > 0 else { return nil }
            state.responseBuffer.append(contentsOf: bytes.prefix(count))
            guard
                state.responseBuffer.count <= maximumResponseByteCount
            else {
                return nil
            }
        }
    }

    private func closeConnection() {
        guard let current = state else { return }
        Darwin.close(current.socket)
        state = nil
    }
}
