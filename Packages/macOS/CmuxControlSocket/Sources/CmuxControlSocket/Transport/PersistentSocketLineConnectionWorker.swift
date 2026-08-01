internal import Darwin
internal import Dispatch
internal import Foundation

/// Queue-confined mutable state for one persistent socket connection.
final class PersistentSocketLineConnectionWorker: @unchecked Sendable {
    private let queue: DispatchQueue
    private let transport: SocketTransport
    private let maximumResponseByteCount: Int
    private let connectDependencies: PersistentSocketConnectDependencies
    private let activeInterruption = PersistentSocketInterruptionSignal()
    private var state: PersistentSocketLineConnectionState?

    init(
        transport: SocketTransport,
        maximumResponseByteCount: Int,
        queue: DispatchQueue,
        connectDependencies: PersistentSocketConnectDependencies = .live
    ) {
        self.transport = transport
        self.maximumResponseByteCount = maximumResponseByteCount
        self.queue = queue
        self.connectDependencies = connectDependencies
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
        let cancellation = PersistentSocketInterruptionSignal()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                queue.async { [self] in
                    let result = cancellation.isTriggered
                        ? nil
                        : blockingCommand(
                            command,
                            at: socketPath,
                            timeout: timeout,
                            cancellation: cancellation,
                            validatingPeer: validatingPeer
                        )
                    continuation.resume(returning: result)
                }
            }
        } onCancel: {
            cancellation.trigger()
        }
    }

    func invalidate() async {
        activeInterruption.trigger()
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                closeConnection()
                activeInterruption.retire()
                continuation.resume()
            }
        }
    }

    private func blockingCommand(
        _ command: String,
        at socketPath: String,
        timeout: TimeInterval,
        cancellation: PersistentSocketInterruptionSignal,
        validatingPeer: @Sendable (pid_t?) -> Bool
    ) -> (response: String, peerProcessID: pid_t?)? {
        dispatchPrecondition(condition: .onQueue(queue))
        defer { endActiveOperation(cancellation: cancellation) }
        guard
            !operationWasInterrupted(cancellation),
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
            deadline: deadline,
            cancellation: cancellation,
            validatingPeer: validatingPeer
        ), var current = state else {
            return nil
        }
        guard publishActiveSocket(
            current.socket,
            cancellation: cancellation
        ), !operationWasInterrupted(cancellation) else {
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
        deadline: TimeInterval,
        cancellation: PersistentSocketInterruptionSignal,
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
            deadline: deadline,
            cancellation: cancellation,
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
        deadline: TimeInterval,
        cancellation: PersistentSocketInterruptionSignal,
        validatingPeer: @Sendable (pid_t?) -> Bool
    ) -> PersistentSocketLineConnectionState? {
        let socket = connectDependencies.makeSocket()
        guard socket >= 0 else { return nil }
        var shouldClose = true
        defer {
            if shouldClose {
                closeSocket(socket)
            }
        }
        guard
            transport.configureCloseOnExec(socket) == nil,
            transport.configureNoSigPipe(socket) == nil,
            transport.configureNonBlocking(socket) == nil
        else {
            return nil
        }
        transport.configureSocketTimeouts(socket, timeout: timeout)
        guard
            publishActiveSocket(socket, cancellation: cancellation),
            !operationWasInterrupted(cancellation)
        else {
            return nil
        }

        let connectResult = connectDependencies.connect(socket, socketPath)
        if connectResult != 0 {
            let connectError = errno
            guard
                connectionIsInProgress(connectError),
                waitForConnection(
                    socket,
                    deadline: deadline,
                    cancellation: cancellation
                )
            else {
                return nil
            }
        }
        guard
            !operationWasInterrupted(cancellation),
            transport.configureBlocking(socket) == nil
        else {
            return nil
        }
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

    private func waitForConnection(
        _ socket: Int32,
        deadline: TimeInterval,
        cancellation: PersistentSocketInterruptionSignal
    ) -> Bool {
        while !operationWasInterrupted(cancellation) {
            guard let remaining = remainingTimeoutMilliseconds(
                until: deadline
            ) else {
                return false
            }
            var descriptor = pollfd(
                fd: socket,
                events: Int16(POLLOUT | POLLERR | POLLHUP),
                revents: 0
            )
            let pollResult = Darwin.poll(
                &descriptor,
                1,
                min(remaining, 50)
            )
            if pollResult < 0, errno == EINTR {
                continue
            }
            if pollResult == 0 {
                continue
            }
            guard pollResult > 0, !operationWasInterrupted(cancellation) else {
                return false
            }
            var socketError: Int32 = 0
            var socketErrorLength = socklen_t(MemoryLayout<Int32>.size)
            let socketErrorResult = withUnsafeMutablePointer(
                to: &socketError
            ) { pointer in
                Darwin.getsockopt(
                    socket,
                    SOL_SOCKET,
                    SO_ERROR,
                    pointer,
                    &socketErrorLength
                )
            }
            return socketErrorResult == 0 && socketError == 0
        }
        return false
    }

    private func connectionIsInProgress(_ errorCode: Int32) -> Bool {
        errorCode == EINPROGRESS ||
            errorCode == EALREADY ||
            errorCode == EAGAIN ||
            errorCode == EWOULDBLOCK
    }

    private func readResponseLine(
        from state: inout PersistentSocketLineConnectionState,
        deadline: TimeInterval,
        cancellation: PersistentSocketInterruptionSignal
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
                !operationWasInterrupted(cancellation),
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

    private func publishActiveSocket(
        _ socket: Int32,
        cancellation: PersistentSocketInterruptionSignal
    ) -> Bool {
        guard cancellation.install(socket: socket) else {
            return false
        }
        guard activeInterruption.install(socket: socket) else {
            cancellation.retire()
            return false
        }
        return true
    }

    private func endActiveOperation(
        cancellation: PersistentSocketInterruptionSignal
    ) {
        cancellation.retire()
        activeInterruption.retire()
    }

    private func operationWasInterrupted(
        _ cancellation: PersistentSocketInterruptionSignal
    ) -> Bool {
        cancellation.isTriggered || activeInterruption.isTriggered
    }

    private func closeSocket(_ socket: Int32) {
        Darwin.close(socket)
    }

    private func closeConnection() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let current = state else { return }
        closeSocket(current.socket)
        state = nil
    }
}
