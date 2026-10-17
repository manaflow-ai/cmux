#if canImport(Network)
import Foundation
import Network

/// A small localhost TCP adapter for agents that need a persistent session.
/// Authentication and remote exposure belong above this transport; by design
/// callers must opt into forwarding this socket beyond loopback.
public final class PhoneTCPServer: @unchecked Sendable {
    private final class ConnectionState: @unchecked Sendable {
        var decoder = PhoneLineDecoder()
    }

    private let listener: NWListener
    private let queue: DispatchQueue
    private let controlServer: PhoneControlServer
    private var readyContinuation: CheckedContinuation<UInt16, Error>?
    private var readyResult: Result<UInt16, Error>?

    public init(
        port: UInt16 = 0,
        driver: any PhoneDriver,
        queue: DispatchQueue = DispatchQueue(label: "com.cmux.phone-control.tcp")
    ) throws {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            throw PhoneDriverError.transport("invalid TCP port")
        }
        listener = try NWListener(using: .tcp, on: endpointPort)
        self.queue = queue
        controlServer = PhoneControlServer(driver: driver)
    }

    public var port: UInt16? {
        listener.port?.rawValue
    }

    public func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
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
            listener.start(queue: queue)
        }
    }

    public func stop() {
        listener.cancel()
    }

    private func finishReady(_ result: Result<UInt16, Error>) {
        guard let continuation = readyContinuation else {
            readyResult = result
            return
        }
        readyContinuation = nil
        continuation.resume(with: result)
    }

    private func accept(_ connection: NWConnection) {
        let state = ConnectionState()
        connection.stateUpdateHandler = { state in
            if case .failed = state {
                connection.cancel()
            }
        }
        connection.start(queue: queue)
        receive(on: connection, state: state)
    }

    private func receive(on connection: NWConnection, state: ConnectionState) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: PhoneProtocol.maxLineBytes) {
            [weak self, weak connection] data, _, isComplete, error in
            guard let self, let connection else { return }
            if let error {
                connection.cancel()
                _ = error
                return
            }
            if let data, !data.isEmpty {
                do {
                    let requests = try state.decoder.append(data)
                    Task {
                        var output = Data()
                        let codec = PhoneWireCodec()
                        for request in requests {
                            for response in await self.controlServer.handle(request) {
                                output.append(try codec.encode(response))
                            }
                        }
                        connection.send(content: output, completion: .contentProcessed { [weak self, weak connection] _ in
                            guard let self, let connection else { return }
                            self.receive(on: connection, state: state)
                        })
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
                connection.cancel()
            } else {
                self.receive(on: connection, state: state)
            }
        }
    }
}
#endif
