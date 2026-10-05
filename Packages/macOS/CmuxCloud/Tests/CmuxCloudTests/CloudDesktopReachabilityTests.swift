@testable import CmuxCloud
import Foundation
import Network
import Testing

/// The desktop probe decides whether opening display 1 first runs the
/// control plane's desktop repair (a guest exec of 10s or more). A slow or
/// silent proxy must not be mistaken for a stopped desktop.
@Suite("Cloud desktop reachability")
struct CloudDesktopReachabilityTests {
    /// A loopback proxy that accepts connections and handles each one with `reply`.
    private final class FakeProxy: @unchecked Sendable {
        let listener: NWListener
        private var connections: [NWConnection] = []
        private let queue = DispatchQueue(label: "fake-proxy")

        init(reply: @escaping @Sendable (NWConnection) -> Void) throws {
            listener = try NWListener(using: .tcp, on: .any)
            listener.newConnectionHandler = { [weak self] connection in
                self?.queue.async { self?.connections.append(connection) }
                connection.start(queue: DispatchQueue(label: "fake-proxy-connection"))
                reply(connection)
            }
        }

        func start() async throws -> UInt16 {
            listener.start(queue: queue)
            for _ in 0..<200 {
                if let port = listener.port?.rawValue, port != 0 { return port }
                try await Task.sleep(for: .milliseconds(10))
            }
            throw CancellationError()
        }

        func stop() {
            listener.cancel()
            queue.sync { connections.forEach { $0.cancel() } }
        }
    }

    private func endpoint(_ port: UInt16) -> CloudBrowserProxyEndpoint {
        CloudBrowserProxyEndpoint(host: "127.0.0.1", port: port, username: "user", password: "pass")
    }

    @Test("A proxy that never answers is unknown within the deadline, not unreachable")
    func silentProxyIsUnknownAtTheDeadline() async throws {
        let proxy = try FakeProxy { _ in }
        defer { proxy.stop() }
        let port = try await proxy.start()
        let started = ContinuousClock.now
        let result = try await CloudBrowserRouting.desktopReachability(
            endpoint: endpoint(port), address: "10.0.0.7", port: 6901, timeout: .milliseconds(500)
        )
        #expect(result == .unknown)
        #expect(ContinuousClock.now - started < .seconds(2), "the deadline must cancel the stalled request")
    }

    @Test("A refused upstream is unreachable")
    func refusedUpstreamIsUnreachable() async throws {
        let proxy = try FakeProxy { connection in
            connection.send(content: Data("HTTP/1.1 502 Bad Gateway\r\n\r\n".utf8), completion: .contentProcessed { _ in })
        }
        defer { proxy.stop() }
        let port = try await proxy.start()
        let result = try await CloudBrowserRouting.desktopReachability(
            endpoint: endpoint(port), address: "10.0.0.7", port: 6901, timeout: .seconds(2)
        )
        #expect(result == .unreachable)
    }
}
