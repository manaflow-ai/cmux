import Foundation
import Synchronization
import Testing
@testable import CmuxNextDaemon

/// architecture.md 5a: every control-plane request has a deadline; a daemon
/// that never answers produces a typed timeout, never a hang.
@Suite(.timeLimit(.minutes(1))) struct DeadlineTests {
    @Test func requestToAStalledDaemonTimesOut() async throws {
        let server = try FakeDaemonServer(handler: ConnectionTests.handshake { _, _ in [] })
        defer { server.stop() }
        let connection = DaemonConnection(endpoint: DaemonEndpoint(socketPath: server.path))
        try await connection.start()
        let started = ContinuousClock.now
        do {
            _ = try await connection.request(ListAgentsRequest())
            Issue.record("expected a timeout")
        } catch let error as DaemonError {
            guard case .timedOut = error else {
                Issue.record("expected timedOut, got \(error)")
                return
            }
        }
        #expect(ContinuousClock.now - started < .seconds(5))
        await connection.close()
    }

    @Test func aLateReplyAfterATimeoutDoesNotAnswerTheNextRequest() async throws {
        // The first list-agents is answered only after the second arrives,
        // with the first id; the second then gets its own reply.
        let seen = Mutex<[Int]>([])
        let server = try FakeDaemonServer(handler: ConnectionTests.handshake { request, id in
            guard request["cmd"]?.stringValue == "list-agents" else { return [] }
            let ids = seen.withLock { ids -> [Int] in
                ids.append(id)
                return ids
            }
            guard ids.count == 2 else { return [] }
            return ids.map { #"{"id":\#($0),"ok":true,"data":{"agents":[{"surface":\#($0),"state":"idle","source":"hook","session":null,"updated_at_ms":1}]}}"# }
        })
        defer { server.stop() }
        let connection = DaemonConnection(endpoint: DaemonEndpoint(socketPath: server.path))
        try await connection.start()
        await #expect(throws: DaemonError.self) {
            _ = try await connection.request(ListAgentsRequest(), timeout: .milliseconds(100))
        }
        let second = try await connection.request(ListAgentsRequest(), timeout: .seconds(2))
        let ids = seen.withLock { $0 }
        #expect(second.agents.first?.surface.rawValue == UInt64(ids[1]))
        await connection.close()
    }
    /// A spawn that misses the terminal start deadline says the terminal
    /// may still appear: cmux-tui keeps starting it after the client gave up.
    @Test func aSpawnPastTheTerminalStartDeadlineIsATypedTimeout() async throws {
        let server = try FakeDaemonServer(handler: ConnectionTests.handshake { _, _ in [] })
        defer { server.stop() }
        let connection = DaemonConnection(endpoint: DaemonEndpoint(socketPath: server.path),
                                          configuration: .init(spawnTimeout: .milliseconds(200)))
        try await connection.start()
        do {
            _ = try await connection.newPaneInColumn(of: PaneID(rawValue: 1))
            Issue.record("expected a timeout")
        } catch let error as DaemonError {
            guard case .terminalStartTimedOut = error else {
                Issue.record("expected terminalStartTimedOut, got \(error)")
                return
            }
            #expect(error.description.contains("may still appear"))
        }
        await connection.close()
    }

    /// A spawn launches a terminal host, which cmux-tui bounds by its own
    /// host handshake (2 s) plus connect retry (1 s) windows. Under load a
    /// placement can take longer than the 2 s control-plane deadline and
    /// still succeed in the daemon, so the client must not give up first
    /// (it would report a failure for a tab that then appears).
    @Test func aSpawnSlowerThanTheControlPlaneDeadlineSucceeds() async throws {
        let pending = Mutex<Int?>(nil)
        let server = try FakeDaemonServer(handler: ConnectionTests.handshake { request, id in
            guard request["cmd"]?.stringValue == "new-pane" else { return [] }
            pending.withLock { $0 = id }
            return []
        })
        defer { server.stop() }
        let connection = DaemonConnection(endpoint: DaemonEndpoint(socketPath: server.path))
        try await connection.start()
        async let created = connection.newPaneInColumn(of: PaneID(rawValue: 1))
        // The host comes up 2.5 s later, inside the daemon's own bound.
        try await Task.sleep(for: .milliseconds(2500))
        let id = try #require(pending.withLock { $0 })
        server.push(#"{"id":\#(id),"ok":true,"data":{"surface":7}}"#)
        #expect(try await created.surface == SurfaceID(rawValue: 7))
        await connection.close()
    }
}
