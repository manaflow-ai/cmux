#if canImport(Network)
import Foundation
import Network

/// A small localhost TCP adapter for agents that need a persistent session.
/// Authentication and remote exposure belong above this transport; by design
/// callers must opt into forwarding this socket beyond loopback.
public final class PhoneTCPServer: @unchecked Sendable {
    private final class ConnectionState: @unchecked Sendable {
        let id = UUID()
        var decoder = PhoneLineDecoder(maxLineBytes: PhoneProtocol.maxRequestLineBytes)
        let controlServer: PhoneControlServer

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
        self.connections.removeAll()
        stateLock.unlock()
        continuation?.resume(throwing: PhoneDriverError.transport("TCP listener stopped"))
        listener.cancel()
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
                    Task {
                        do {
                            var output = Data()
                            let codec = PhoneWireCodec()
                            for request in requests {
                                for response in await state.controlServer.handle(request) {
                                    output.append(try codec.encode(response))
                                }
                            }
                            connection.send(content: output, completion: .contentProcessed { [weak self, weak connection] error in
                                guard let self, let connection else { return }
                                if error != nil {
                                    self.finishConnection(id: state.id, connection: connection)
                                } else {
                                    self.receive(on: connection, state: state)
                                }
                            })
                        } catch {
                            self.sendErrorAndClose(connection, error: error)
                        }
                    }
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

    private func finishConnection(id: UUID, connection: NWConnection) {
        stateLock.lock()
        connections.removeValue(forKey: id)
        stateLock.unlock()
        connection.cancel()
    }

    private func sendErrorAndClose(_ connection: NWConnection, error: Error) {
        let envelope = PhoneEnvelope.failure(
            id: nil,
            error: PhoneError(code: "response_too_large", message: String(describing: error))
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
