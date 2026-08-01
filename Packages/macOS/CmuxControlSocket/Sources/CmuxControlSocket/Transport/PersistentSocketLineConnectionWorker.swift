internal import Darwin
internal import Dispatch
internal import Foundation

/// Queue-confined mutable state for one persistent socket connection.
final class PersistentSocketLineConnectionWorker: @unchecked Sendable {
    private let queue: DispatchQueue
    private let transport: SocketTransport
    private let maximumResponseByteCount: Int
    private let connectDependencies: PersistentSocketConnectDependencies
    private let didEnqueueCommand: @Sendable () -> Void
    private let activeInterruption = PersistentSocketInterruptionSignal()
    private var state: PersistentSocketLineConnectionState?

    init(
        transport: SocketTransport,
        maximumResponseByteCount: Int,
        queue: DispatchQueue,
        connectDependencies: PersistentSocketConnectDependencies = .live,
        didEnqueueCommand: @escaping @Sendable () -> Void = {}
    ) {
        self.transport = transport
        self.maximumResponseByteCount = maximumResponseByteCount
        self.queue = queue
        self.connectDependencies = connectDependencies
        self.didEnqueueCommand = didEnqueueCommand
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
        let cancellationGeneration = cancellation.begin()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                queue.async { [self] in
                    let result = cancellation.isTriggered(
                        generation: cancellationGeneration
                    )
                        ? nil
                        : blockingCommand(
                            command,
                            at: socketPath,
                            timeout: timeout,
                            cancellation: cancellation,
                            cancellationGeneration: cancellationGeneration,
                            validatingPeer: validatingPeer
                        )
                    continuation.resume(returning: result)
                }
                didEnqueueCommand()
            }
        } onCancel: {
            cancellation.trigger(generation: cancellationGeneration)
        }
    }

    func invalidate() async {
        activeInterruption.triggerCurrentGeneration()
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                closeConnection()
                activeInterruption.retireCurrentGeneration()
                continuation.resume()
            }
        }
    }

    private func blockingCommand(
        _ command: String,
        at socketPath: String,
        timeout: TimeInterval,
        cancellation: PersistentSocketInterruptionSignal,
        cancellationGeneration: UInt32,
        validatingPeer: @Sendable (pid_t?) -> Bool
    ) -> (response: String, peerProcessID: pid_t?)? {
        dispatchPrecondition(condition: .onQueue(queue))
        let activeGeneration = activeInterruption.begin()
        defer {
            endActiveOperation(
                cancellation: cancellation,
                cancellationGeneration: cancellationGeneration,
                activeGeneration: activeGeneration
            )
        }
        guard
            !operationWasInterrupted(
                cancellation,
                cancellationGeneration: cancellationGeneration,
                activeGeneration: activeGeneration
            ),
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
            cancellationGeneration: cancellationGeneration,
            activeGeneration: activeGeneration,
            validatingPeer: validatingPeer
        ), var current = state else {
            return nil
        }
        guard publishActiveSocket(
            current.socket,
            cancellation: cancellation,
            cancellationGeneration: cancellationGeneration,
            activeGeneration: activeGeneration
        ), !operationWasInterrupted(
            cancellation,
            cancellationGeneration: cancellationGeneration,
            activeGeneration: activeGeneration
        ) else {
            closeConnection()
            return nil
        }
        guard validatingPeer(current.peerProcessID) else {
            closeConnection()
            return nil
        }
        guard transport.writeAll(
            Data((command + "\n").utf8),
            to: current.socket,
            deadline: deadline,
            isInterrupted: { [self] in
                operationWasInterrupted(
                    cancellation,
                    cancellationGeneration: cancellationGeneration,
                    activeGeneration: activeGeneration
                )
            }
        ), let response = readResponseLine(
            from: &current,
            deadline: deadline,
            cancellation: cancellation,
            cancellationGeneration: cancellationGeneration,
            activeGeneration: activeGeneration
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
        cancellationGeneration: UInt32,
        activeGeneration: UInt32,
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
            cancellationGeneration: cancellationGeneration,
            activeGeneration: activeGeneration,
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
        cancellationGeneration: UInt32,
        activeGeneration: UInt32,
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
        guard transport.configureUnixClientSocket(
            socket,
            timeout: timeout,
            nonBlocking: true
        ) else {
            return nil
        }
        guard
            publishActiveSocket(
                socket,
                cancellation: cancellation,
                cancellationGeneration: cancellationGeneration,
                activeGeneration: activeGeneration
            ),
            !operationWasInterrupted(
                cancellation,
                cancellationGeneration: cancellationGeneration,
                activeGeneration: activeGeneration
            )
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
                    cancellation: cancellation,
                    cancellationGeneration: cancellationGeneration,
                    activeGeneration: activeGeneration
                )
            else {
                return nil
            }
        }
        guard
            !operationWasInterrupted(
                cancellation,
                cancellationGeneration: cancellationGeneration,
                activeGeneration: activeGeneration
            ),
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
        cancellation: PersistentSocketInterruptionSignal,
        cancellationGeneration: UInt32,
        activeGeneration: UInt32
    ) -> Bool {
        while !operationWasInterrupted(
            cancellation,
            cancellationGeneration: cancellationGeneration,
            activeGeneration: activeGeneration
        ) {
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
            guard pollResult > 0, !operationWasInterrupted(
                cancellation,
                cancellationGeneration: cancellationGeneration,
                activeGeneration: activeGeneration
            ) else {
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
        cancellation: PersistentSocketInterruptionSignal,
        cancellationGeneration: UInt32,
        activeGeneration: UInt32
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
                !operationWasInterrupted(
                    cancellation,
                    cancellationGeneration: cancellationGeneration,
                    activeGeneration: activeGeneration
                ),
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
        cancellation: PersistentSocketInterruptionSignal,
        cancellationGeneration: UInt32,
        activeGeneration: UInt32
    ) -> Bool {
        guard cancellation.install(
            socket: socket,
            generation: cancellationGeneration
        ) else {
            return false
        }
        guard activeInterruption.install(
            socket: socket,
            generation: activeGeneration
        ) else {
            _ = cancellation.retire(generation: cancellationGeneration)
            return false
        }
        return true
    }

    private func endActiveOperation(
        cancellation: PersistentSocketInterruptionSignal,
        cancellationGeneration: UInt32,
        activeGeneration: UInt32
    ) {
        let commandWasInterrupted = cancellation.retire(
            generation: cancellationGeneration
        )
        let activeOperationWasInterrupted = activeInterruption.retire(
            generation: activeGeneration
        )
        if commandWasInterrupted || activeOperationWasInterrupted {
            closeConnection()
        }
    }

    private func operationWasInterrupted(
        _ cancellation: PersistentSocketInterruptionSignal,
        cancellationGeneration: UInt32,
        activeGeneration: UInt32
    ) -> Bool {
        cancellation.isTriggered(generation: cancellationGeneration) ||
            activeInterruption.isTriggered(generation: activeGeneration)
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
