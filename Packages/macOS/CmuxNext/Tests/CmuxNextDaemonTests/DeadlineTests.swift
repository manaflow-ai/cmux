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
}
