internal import Darwin
internal import Dispatch
internal import Foundation

/// Queue-confined mutable state for one persistent socket connection.
final class PersistentSocketLineConnectionWorker: @unchecked Sendable {
    private let queue: DispatchQueue
    private let transport: SocketTransport
    private let maximumResponseByteCount: Int
    private let activeOperationLock = NSLock()
    private var activeOperationID: UUID?
    private var activeOperationSocket: Int32?
    private var state: PersistentSocketLineConnectionState?

    init(
        transport: SocketTransport,
        maximumResponseByteCount: Int,
        queue: DispatchQueue
    ) {
        self.transport = transport
        self.maximumResponseByteCount = maximumResponseByteCount
        self.queue = queue
    }

    deinit {
        if let state {
            closeSocket(state.socket)
        }
    }

    func command(
        _ command: String,
        at socketPath: String,
        timeout: TimeInterval,
        validatingPeer: @escaping @Sendable (pid_t?) -> Bool
    ) async -> (response: String, peerProcessID: pid_t?)? {
        let operationID = UUID()
        let cancellation = PersistentSocketLineCommandCancellation()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                queue.async { [self] in
                    let result = cancellation.isCancelled
                        ? nil
                        : blockingCommand(
                            command,
                            at: socketPath,
                            timeout: timeout,
                            operationID: operationID,
                            cancellation: cancellation,
                            validatingPeer: validatingPeer
                        )
                    continuation.resume(returning: result)
                }
            }
        } onCancel: { [self] in
            cancellation.cancel()
            interruptActiveOperation(operationID)
        }
    }

    func invalidate() async {
        interruptActiveOperation()
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                closeConnection()
                continuation.resume()
            }
        }
    }

    private func blockingCommand(
        _ command: String,
        at socketPath: String,
        timeout: TimeInterval,
        operationID: UUID,
        cancellation: PersistentSocketLineCommandCancellation,
        validatingPeer: @Sendable (pid_t?) -> Bool
    ) -> (response: String, peerProcessID: pid_t?)? {
        dispatchPrecondition(condition: .onQueue(queue))
        beginActiveOperation(operationID)
        defer { endActiveOperation(operationID) }
        guard
            !cancellation.isCancelled,
            timeout.isFinite,
            timeout > 0,
            !command.contains("\n"),
            !command.contains("\r")
        else {
            return nil
        }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        guard ensureConnection(
            at: socketPath,
            timeout: timeout,
            validatingPeer: validatingPeer
        ), var current = state else {
            return nil
        }
        setActiveOperationSocket(
            current.socket,
            operationID: operationID
        )
        guard !cancellation.isCancelled else {
            closeConnection()
            return nil
        }
        guard validatingPeer(current.peerProcessID) else {
            closeConnection()
            return nil
        }
        guard transport.writeAll(
            Data((command + "\n").utf8),
            to: current.socket
        ), let response = readResponseLine(
            from: &current,
            deadline: deadline,
            cancellation: cancellation
        ) else {
            closeConnection()
            return nil
        }
        state = current
        return (
            response: response,
            peerProcessID: current.peerProcessID
        )
    }

    private func ensureConnection(
        at socketPath: String,
        timeout: TimeInterval,
        validatingPeer: @Sendable (pid_t?) -> Bool
    ) -> Bool {
        if var current = state {
            if
                current.path == socketPath,
                validatingPeer(current.peerProcessID)
            {
                if current.timeout != timeout {
                    transport.configureSocketTimeouts(
                        current.socket,
                        timeout: timeout
                    )
                    current.timeout = timeout
                    state = current
                }
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
    ) -> PersistentSocketLineConnectionState? {
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
        return PersistentSocketLineConnectionState(
            socket: socket,
            path: socketPath,
            timeout: timeout,
            peerProcessID: peerProcessID
        )
    }

    private func readResponseLine(
        from state: inout PersistentSocketLineConnectionState,
        deadline: TimeInterval,
        cancellation: PersistentSocketLineCommandCancellation
    ) -> String? {
        while true {
            if let newline = state.responseBuffer.firstIndex(of: 0x0A) {
                let line = state.responseBuffer[..<newline]
                state.responseBuffer.removeSubrange(
                    state.responseBuffer.startIndex ... newline
                )
                return String(data: line, encoding: .utf8)
            }
            guard
                !cancellation.isCancelled,
                let timeoutMilliseconds = remainingTimeoutMilliseconds(
                    until: deadline
                )
            else {
                return nil
            }
            var descriptor = pollfd(
                fd: state.socket,
                events: Int16(POLLIN | POLLHUP),
                revents: 0
            )
            let pollResult = Darwin.poll(
                &descriptor,
                1,
                timeoutMilliseconds
            )
            if pollResult < 0, errno == EINTR {
                continue
            }
            guard
                pollResult > 0,
                descriptor.revents & Int16(POLLIN | POLLHUP) != 0
            else {
                return nil
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

    private func remainingTimeoutMilliseconds(
        until deadline: TimeInterval
    ) -> Int32? {
        let remaining =
            deadline - ProcessInfo.processInfo.systemUptime
        guard remaining > 0 else { return nil }
        return Int32(min(
            ceil(remaining * 1_000),
            Double(Int32.max)
        ))
    }

    private func beginActiveOperation(_ operationID: UUID) {
        activeOperationLock.lock()
        activeOperationID = operationID
        activeOperationSocket = nil
        activeOperationLock.unlock()
    }

    private func setActiveOperationSocket(
        _ socket: Int32,
        operationID: UUID
    ) {
        activeOperationLock.lock()
        if activeOperationID == operationID {
            activeOperationSocket = socket
        }
        activeOperationLock.unlock()
    }

    private func endActiveOperation(_ operationID: UUID) {
        activeOperationLock.lock()
        if activeOperationID == operationID {
            activeOperationID = nil
            activeOperationSocket = nil
        }
        activeOperationLock.unlock()
    }

    private func interruptActiveOperation(_ operationID: UUID? = nil) {
        activeOperationLock.lock()
        defer { activeOperationLock.unlock() }
        guard
            operationID == nil || activeOperationID == operationID,
            let socket = activeOperationSocket
        else {
            return
        }
        Darwin.shutdown(socket, SHUT_RDWR)
    }

    private func closeSocket(_ socket: Int32) {
        activeOperationLock.lock()
        if activeOperationSocket == socket {
            activeOperationSocket = nil
        }
        Darwin.close(socket)
        activeOperationLock.unlock()
    }

    private func closeConnection() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let current = state else { return }
        closeSocket(current.socket)
        state = nil
    }
}

private final class PersistentSocketLineCommandCancellation:
    @unchecked Sendable
{
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}
