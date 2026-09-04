import Foundation
import Network

/// Loopback-only HTTP fixture with signal-driven readiness. Network framework
/// owns the thread-safe immutable listener; connections close after one reply.
final class ChromiumHTTPFixture: @unchecked Sendable {
    private let listener: NWListener
    private let readiness: AsyncThrowingStream<UInt16, any Error>

    init(html: String) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        let pair = AsyncThrowingStream<UInt16, any Error>.makeStream(bufferingPolicy: .bufferingNewest(1))
        readiness = pair.stream
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                if let port = listener.port { pair.continuation.yield(port.rawValue); pair.continuation.finish() }
            case .failed(let error): pair.continuation.finish(throwing: error)
            case .cancelled: pair.continuation.finish()
            default: break
            }
        }
        let body = Data(html.utf8)
        var response = Data("HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
        response.append(body)
        let bytes = response
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { _, _, _, _ in
                connection.send(content: bytes, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
    }

    func start() async throws -> URL {
        listener.start(queue: .global())
        for try await port in readiness { return URL(string: "http://127.0.0.1:\(port)/")! }
        throw CancellationError()
    }

    func stop() { listener.cancel() }
    deinit { listener.cancel() }
}
