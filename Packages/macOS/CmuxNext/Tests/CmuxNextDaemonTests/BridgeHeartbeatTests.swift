import Foundation
import Synchronization
import Testing
@testable import CmuxNextDaemon

/// A bridged (overlay) connection asks the daemon `identify` every
/// `bridgeHeartbeat`; `bridgeHeartbeatMisses` unanswered asks close it, so a
/// lost server never hangs it. A plain socket connection asks nothing.
@Suite(.timeLimit(.minutes(1))) struct BridgeHeartbeatTests {
    /// A daemon that answers the handshake identify, then only `answered`
    /// more identifies, and counts every identify it gets.
    /// Counts identify requests across the fake daemon's threads.
    final class Count: Sendable {
        let value = Mutex(0)
        var current: Int { value.withLock { $0 } }
    }

    static func server(answered: Int, identifies: Count) throws -> FakeDaemonServer {
        let handshake = ConnectionTests.handshake { _, _ in [] }
        return try FakeDaemonServer { request in
            guard request["cmd"]?.stringValue == "identify" else { return handshake(request) }
            let count = identifies.value.withLock { count -> Int in
                count += 1
                return count
            }
            return count <= answered + 1 ? handshake(request) : []
        }
    }

    /// `/bin/sh` reporting an ok dial and bridging stdio to `socket`, as
    /// `cmux link dial` does to the server.
    static func bridge(to socket: String) -> DaemonBridge {
        DaemonBridge(executable: "/bin/sh", arguments: ["-c", #"printf '{"ok":true}\n' >&2; exec /usr/bin/nc -U "$0""#, socket])
    }

    static var fast: DaemonConnection.Configuration {
        var configuration = DaemonConnection.Configuration()
        configuration.bridgeHeartbeat = .milliseconds(150)
        return configuration
    }

    @Test func aBridgedConnectionWhoseServerStopsAnsweringCloses() async throws {
        let identifies = Count()
        let server = try Self.server(answered: 1, identifies: identifies)
        defer { server.stop() }
        let endpoint = DaemonEndpoint(socketPath: server.path, bridge: Self.bridge(to: server.path))
        let connection = DaemonConnection(endpoint: endpoint, configuration: Self.fast)
        try await connection.start()
        var iterator = connection.events.makeAsyncIterator()
        guard case .connected? = try await iterator.next()?.event else {
            Issue.record("missing connect")
            return
        }
        // One answered heartbeat, then two unanswered ones: the connection ends.
        var sawDisconnect = false
        while let envelope = try await iterator.next() {
            if case .disconnected = envelope.event {
                sawDisconnect = true
                break
            }
        }
        #expect(sawDisconnect)
        #expect(identifies.current >= 4)
        await connection.close()
    }

    @Test func anAnsweringServerKeepsTheBridgedConnection() async throws {
        let identifies = Count()
        let server = try Self.server(answered: 1_000, identifies: identifies)
        defer { server.stop() }
        let endpoint = DaemonEndpoint(socketPath: server.path, bridge: Self.bridge(to: server.path))
        let connection = DaemonConnection(endpoint: endpoint, configuration: Self.fast)
        try await connection.start()
        let disconnects = Count()
        let watcher = Task {
            for try await envelope in connection.events {
                if case .disconnected = envelope.event { disconnects.value.withLock { $0 += 1 } }
            }
        }
        try await Task.sleep(for: .milliseconds(800))
        #expect(disconnects.current == 0, "an answering server keeps the bridged connection")
        // Only the heartbeat asks identify after the handshake (no reconnect).
        #expect(identifies.current >= 4, "the heartbeat asks while connected")
        watcher.cancel()
        await connection.close()
    }

    @Test func aSocketConnectionSendsNoHeartbeat() async throws {
        let identifies = Count()
        let server = try Self.server(answered: 0, identifies: identifies)
        defer { server.stop() }
        let connection = DaemonConnection(endpoint: DaemonEndpoint(socketPath: server.path), configuration: Self.fast)
        try await connection.start()
        try await Task.sleep(for: .milliseconds(600))
        #expect(identifies.current == 1, "only the handshake identify")
        await connection.close()
    }
}
