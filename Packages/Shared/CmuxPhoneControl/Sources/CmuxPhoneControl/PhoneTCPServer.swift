#if canImport(Network)
import Foundation
import Network

/// A small localhost TCP adapter for agents that need a persistent session.
/// Authentication and remote exposure belong above this transport; by design
/// callers must opt into forwarding this socket beyond loopback.
public final class PhoneTCPServer: @unchecked Sendable {
    private final class TaskStartGate: @unchecked Sendable {
        private let lock = NSLock()
        private var opened = false
        private var continuation: CheckedContinuation<Void, Never>?

        func wait() async {
            await withCheckedContinuation { continuation in
                lock.lock()
                if opened {
                    lock.unlock()
                    continuation.resume()
                } else {
                    self.continuation = continuation
                    lock.unlock()
                }
            }
        }

        func open() {
            lock.lock()
            guard !opened else {
                lock.unlock()
                return
            }
            opened = true
            let continuation = self.continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume()
        }
    }

    private final class ConnectionState: @unchecked Sendable {
        let id = UUID()
        var decoder = PhoneLineDecoder(maxLineBytes: PhoneProtocol.maxRequestLineBytes)
        let controlServer: PhoneControlServer
        /// Mutated only while the owning `PhoneTCPServer.stateLock` is held.
        var leaseHeld = false

        init(driver: any PhoneDriver) {
            controlServer = PhoneControlServer(driver: driver)
        }
    }

    private let listener: NWListener
    private let queue: DispatchQueue
    private let driver: any PhoneDriver
    private let stateLock = NSLock()
    private var readyContinuation: CheckedContinuation<UInt16, Error>?
    private var readyPort: UInt16?
    private var startInProgress = false
    private var stopped = false
    private var connections: [UUID: NWConnection] = [:]
    private var connectionTasks: [UUID: Task<Void, Never>] = [:]
    private var leaseOwner: UUID?

    public init(
        port: UInt16 = 0,
        driver: any PhoneDriver,
        queue: DispatchQueue = DispatchQueue(label: "com.cmux.phone-control.tcp")
    ) throws {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            throw PhoneDriverError.transport("invalid TCP port")
        }
        let parameters = NWParameters.tcp
        let localPort: NWEndpoint.Port = endpointPort.rawValue == 0 ? .any : endpointPort
        parameters.requiredLocalEndpoint = .hostPort(
            host: NWEndpoint.Host("127.0.0.1"),
            port: localPort
        )
        listener = try NWListener(using: parameters)
        self.queue = queue
        self.driver = driver
    }

    public var port: UInt16? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return readyPort
    }

    public func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            stateLock.lock()
            if stopped {
                stateLock.unlock()
                continuation.resume(throwing: PhoneDriverError.transport("TCP listener stopped"))
                return
            }
            if let readyPort {
                stateLock.unlock()
                continuation.resume(returning: readyPort)
                return
            }
            if startInProgress {
                stateLock.unlock()
                continuation.resume(throwing: PhoneDriverError.transport("TCP listener start already in progress"))
                return
            }
            startInProgress = true
            readyContinuation = continuation
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.finishReady(.success(self.listener.port?.rawValue ?? 0))
                case .failed(let error):
                    self.finishReady(.failure(error))
                case .cancelled:
                    self.finishReady(.failure(PhoneDriverError.transport("TCP listener cancelled")))
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            stateLock.unlock()
            listener.start(queue: queue)
        }
    }

    public func stop() {
        stateLock.lock()
        stopped = true
        startInProgress = false
        let continuation = readyContinuation
        readyContinuation = nil
        readyPort = nil
        let connections = Array(self.connections.values)
        let tasks = Array(self.connectionTasks.values)
        self.connections.removeAll()
        self.connectionTasks.removeAll()
        leaseOwner = nil
        stateLock.unlock()
        continuation?.resume(throwing: PhoneDriverError.transport("TCP listener stopped"))
        listener.cancel()
        for task in tasks {
            task.cancel()
        }
        for connection in connections {
            connection.cancel()
        }
    }

    private func finishReady(_ result: Result<UInt16, Error>) {
        stateLock.lock()
        var result = result
        if case .success(let port) = result, port == 0 {
            result = .failure(PhoneDriverError.transport("TCP listener reported no port"))
        }
        if case .success(let port) = result {
            if stopped {
                result = .failure(PhoneDriverError.transport("TCP listener stopped"))
            } else {
                readyPort = port
            }
        }
        if case .failure = result {
            readyPort = nil
            if !stopped { stopped = true }
        }
        startInProgress = false
        let continuation = readyContinuation
        readyContinuation = nil
        stateLock.unlock()
        guard let continuation else { return }
        continuation.resume(with: result)
    }

    private func accept(_ connection: NWConnection) {
        let state = ConnectionState(driver: driver)
        stateLock.lock()
        guard !stopped else {
            stateLock.unlock()
            connection.cancel()
            return
        }
        connections[state.id] = connection
        stateLock.unlock()

        connection.stateUpdateHandler = { [weak self, weak connection] networkState in
            guard let self, let connection else { return }
            switch networkState {
            case .failed, .cancelled:
                self.finishConnection(id: state.id, connection: connection)
            default:
                break
            }
        }
        connection.start(queue: queue)
        receive(on: connection, state: state)
    }

    private func receive(on connection: NWConnection, state: ConnectionState) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: PhoneProtocol.maxRequestLineBytes) {
            [weak self, weak connection] data, _, isComplete, error in
            guard let self, let connection else { return }
            if let error {
                self.finishConnection(id: state.id, connection: connection)
                _ = error
                return
            }
            if let data, !data.isEmpty {
                do {
                    let requests = try state.decoder.append(data)
                    guard !requests.isEmpty else {
                        self.receive(on: connection, state: state)
                        return
                    }
                    self.startRequestTask(
                        requests,
                        on: connection,
                        state: state
                    )
                } catch {
                    let envelope = PhoneEnvelope.failure(
                        id: nil,
                        error: PhoneError(code: "invalid_frame", message: String(describing: error))
                    )
                    if let encoded = try? PhoneWireCodec().encode(envelope) {
                        connection.send(content: encoded, completion: .contentProcessed { _ in
                            connection.cancel()
                        })
                    } else {
                        connection.cancel()
                    }
                }
            } else if isComplete {
                self.finishConnection(id: state.id, connection: connection)
            } else {
                self.receive(on: connection, state: state)
            }
        }
    }

    private func startRequestTask(
        _ requests: [PhoneEnvelope],
        on connection: NWConnection,
        state: ConnectionState
    ) {
        let startGate = TaskStartGate()
        let task = Task { [weak self, weak connection, state] in
            guard let self, let connection else { return }
            await startGate.wait()
            defer { self.clearTask(id: state.id) }

            do {
                let codec = PhoneWireCodec()
                for request in requests {
                    try Task.checkCancellation()
                    guard self.isConnectionActive(id: state.id, connection: connection) else {
                        return
                    }
                    let leaseWasHeld = self.leaseHeld(for: state)
                    if request.method == "session.open" && !leaseWasHeld {
                        guard self.acquireLease(for: state) else {
                            let envelope = PhoneEnvelope.failure(
                                id: request.id,
                                error: PhoneError(
                                    code: "device_busy",
                                    message: "the phone is already controlled by another connection",
                                    retryable: true
                                )
                            )
                            try await self.send(codec.encode(envelope), on: connection)
                            continue
                        }
                    }

                    let responses = await state.controlServer.handle(request)
                    let opened = request.method == "session.open"
                        && responses.contains { $0.type == .response && $0.sessionID != nil }
                    if request.method == "session.open", !opened, !leaseWasHeld {
                        self.releaseLease(for: state)
                    }
                    let closed = request.method == "session.close"
                        && responses.contains { $0.type == .response }
                    for response in responses {
                        try Task.checkCancellation()
                        guard self.isConnectionActive(id: state.id, connection: connection) else {
                            return
                        }
                        try await self.send(codec.encode(response), on: connection)
                    }
                    if closed {
                        self.releaseLease(for: state)
                    }
                }
                try Task.checkCancellation()
                guard self.isConnectionActive(id: state.id, connection: connection) else {
                    return
                }
                self.receive(on: connection, state: state)
            } catch is CancellationError {
                self.finishConnection(id: state.id, connection: connection)
            } catch {
                self.sendErrorAndClose(connection, error: error)
            }
        }

        stateLock.lock()
        guard !stopped, connections[state.id] === connection else {
            stateLock.unlock()
            task.cancel()
            startGate.open()
            return
        }
        connectionTasks[state.id] = task
        stateLock.unlock()
        startGate.open()
    }

    private func clearTask(id: UUID) {
        stateLock.lock()
        connectionTasks.removeValue(forKey: id)
        stateLock.unlock()
    }

    private func isConnectionActive(id: UUID, connection: NWConnection) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return !stopped && connections[id] === connection
    }

    private func leaseHeld(for state: ConnectionState) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return state.leaseHeld
    }

    private func acquireLease(for state: ConnectionState) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !stopped, connections[state.id] != nil else { return false }
        if let leaseOwner, leaseOwner != state.id {
            return false
        }
        leaseOwner = state.id
        state.leaseHeld = true
        return true
    }

    private func releaseLease(for state: ConnectionState) {
        stateLock.lock()
        if leaseOwner == state.id {
            leaseOwner = nil
        }
        state.leaseHeld = false
        stateLock.unlock()
    }

    private func send(_ data: Data, on connection: NWConnection) async throws {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                connection.send(content: data, completion: .contentProcessed { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                })
            }
        }, onCancel: {
            connection.cancel()
        })
    }

    private func finishConnection(id: UUID, connection: NWConnection) {
        stateLock.lock()
        connections.removeValue(forKey: id)
        let task = connectionTasks.removeValue(forKey: id)
        if leaseOwner == id {
            leaseOwner = nil
        }
        stateLock.unlock()
        task?.cancel()
        connection.cancel()
    }

    private func sendErrorAndClose(_ connection: NWConnection, error: Error) {
        let code: String
        if let codecError = error as? PhoneWireCodecError, codecError == .lineTooLarge {
            code = "response_too_large"
        } else {
            code = "transport_error"
        }
        let envelope = PhoneEnvelope.failure(
            id: nil,
            error: PhoneError(code: code, message: String(describing: error))
        )
        guard let encoded = try? PhoneWireCodec().encode(envelope) else {
            connection.cancel()
            return
        }
        connection.send(content: encoded, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
#endif
