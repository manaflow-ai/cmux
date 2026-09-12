import Foundation
@preconcurrency import Network

/// A real loopback HTTP peer. URLProtocol cannot finish the original response
/// reliably after a redirect delegate refuses its synthetic redirect.
actor CredentialRedirectServer {
    private let listener: NWListener
    private var connections: [UUID: NWConnection] = [:]
    // Network.framework requires a callback delivery queue, not a state lock.
    private let queue = DispatchQueue(label: "cmux.broker-redirect-fixture")

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    func start() async throws -> URL {
        let states = AsyncThrowingStream<Void, Error>.makeStream()
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: states.continuation.yield(()); states.continuation.finish()
            case .failed(let error): states.continuation.finish(throwing: error)
            case .cancelled: states.continuation.finish(throwing: CancellationError())
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { await self?.serve(connection) }
        }
        listener.start(queue: queue)
        for try await _ in states.stream { break }
        listener.stateUpdateHandler = nil
        guard let port = listener.port else { throw URLError(.cannotConnectToHost) }
        return URL(string: "http://127.0.0.1:\(port.rawValue)")!
    }

    func stop() {
        listener.cancel()
        for connection in connections.values { connection.cancel() }
        connections.removeAll()
    }

    private func serve(_ connection: NWConnection) async {
        let id = UUID()
        connections[id] = connection
        connection.start(queue: queue)
        defer { connection.cancel(); connections.removeValue(forKey: id) }
        do {
            var request = Data()
            while request.range(of: Data("\r\n\r\n".utf8)) == nil {
                let chunk: Data = try await withCheckedThrowingContinuation { continuation in
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, done, error in
                        if let error { continuation.resume(throwing: error) }
                        else if let data, !data.isEmpty { continuation.resume(returning: data) }
                        else if done { continuation.resume(throwing: URLError(.networkConnectionLost)) }
                        else { continuation.resume(returning: Data()) }
                    }
                }
                request.append(chunk)
                guard request.count <= 32_768 else { throw URLError(.dataLengthExceedsMaximum) }
            }
            let header = String(decoding: request, as: UTF8.self)
            let response: String
            if header.contains(" /capture ") {
                response = "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            } else {
                let status = header.contains(" /308 ") ? 308 : 307
                let port = listener.port!.rawValue
                response = "HTTP/1.1 \(status) Redirect\r\nLocation: http://localhost:\(port)/capture\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            }
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                connection.send(content: Data(response.utf8), completion: .contentProcessed { error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume() }
                })
            }
        } catch { /* The caller observes request failure; always release the peer. */ }
    }
}
