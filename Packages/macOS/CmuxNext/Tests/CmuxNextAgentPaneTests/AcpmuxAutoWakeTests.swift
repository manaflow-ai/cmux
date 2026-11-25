import Foundation
import Testing
@testable import CmuxNextAgentPane

/// Auto's wake notice (``AcpmuxEnvironment/autoSessionWake(deadline:)``,
/// plans/cmux-next/auto-mode/DESIGN.md "Laptop wake"): when macOS wakes, the app tells the acpmux
/// that is running, and only that one.
@Suite(.serialized)
struct AcpmuxAutoWakeTests {
    /// A home and socket of its own per test.
    private static func environment() throws -> (AcpmuxEnvironment, URL) {
        let home = URL(fileURLWithPath: "/tmp/aw-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let environment = AcpmuxEnvironment(executable: URL(fileURLWithPath: "/usr/bin/false"), home: home,
                                            socketPath: home.appendingPathComponent("s.sock").path,
                                            daemonArguments: [], childEnvironment: [:])
        return (environment, home)
    }

    /// The notice is one request on the daemon's socket, after the handshake.
    @Test func theWakeNoticeReachesARunningDaemon() async throws {
        let (environment, home) = try Self.environment()
        defer { try? FileManager.default.removeItem(at: home) }
        let daemon = try FakeDaemon(socketPath: environment.socketPath)
        defer { daemon.stop() }
        #expect(await environment.autoSessionWake(deadline: .seconds(5)))
        #expect(daemon.calls.contains { $0.last == "_acpmux/auto_session/wake" }, "\(daemon.calls)")
    }

    /// With no daemon there is no chat to check: the notice starts none and reports nothing.
    @Test func theWakeNoticeStartsNoDaemon() async throws {
        let (environment, home) = try Self.environment()
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(await environment.autoSessionWake(deadline: .seconds(2)) == false)
        #expect(!FileManager.default.fileExists(atPath: environment.socketPath))
    }
}
