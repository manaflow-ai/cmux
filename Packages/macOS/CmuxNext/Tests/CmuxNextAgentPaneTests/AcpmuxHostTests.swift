import Foundation
import Testing
@testable import CmuxNextAgentPane

/// Runs the host against a stand-in `acpmux` script and a socket nothing
/// listens on.
@Suite struct AcpmuxHostTests {
    private func stoppedDaemon() throws -> (AcpmuxEnvironment, URL) {
        // Short: a socket path must fit sun_path (104 bytes).
        let root = URL(fileURLWithPath: "/tmp/ah-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let executable = root.appendingPathComponent("acpmux")
        let script = #"printf '{"ready":true,"pid":%s,"webUrl":"http://127.0.0.1:5123/?token=tok"}\n' "$$" >&3"#
        try ("#!/bin/sh\n" + script + "\n").write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let socket = root.appendingPathComponent("a.sock").path
        return (AcpmuxEnvironment(executable: executable, home: home, socketPath: socket, daemonArguments: [],
                                  childEnvironment: ["ACPMUX_HOME": home.path, "ACPMUX_SOCKET": socket]), root)
    }

    /// The page retries its handshake after losing the daemon; those retries
    /// restarted a daemon the user had just stopped.
    @Test func aReconnectDoesNotStartAStoppedDaemon() async throws {
        let (environment, root) = try stoppedDaemon()
        defer { try? FileManager.default.removeItem(at: root) }
        let host = AcpmuxHost(environment: environment)
        await #expect(throws: AgentPaneHostError.daemonStopped) {
            try await host.reconnectHandshake(sessionId: "s-1")
        }
        // The launcher makes the daemon's home before it spawns.
        #expect(!FileManager.default.fileExists(atPath: environment.home.path), "acpmux was launched")
    }

    @Test func aFirstHandshakeStartsTheDaemon() async throws {
        let (environment, root) = try stoppedDaemon()
        defer { try? FileManager.default.removeItem(at: root) }
        let handshake = try await AcpmuxHost(environment: environment).handshake(sessionId: nil)
        #expect(handshake.connection?.url.absoluteString == "ws://127.0.0.1:5123/")
        #expect(handshake.connection?.dashboardToken == "tok")
        #expect(handshake.connection?.localAppToken == nil, "no token file: remote-origin")
    }

    /// The LocalApp token changes at every daemon launch, so each handshake reads the file again.
    @Test func everyHandshakeReadsTheLocalAppTokenAgain() async throws {
        let (environment, root) = try stoppedDaemon()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = AcpmuxLocalAppToken.path(home: environment.home)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let first = String(repeating: "1a", count: 32)
        let second = String(repeating: "2b", count: 32)
        try first.write(to: file, atomically: true, encoding: .utf8)
        let host = AcpmuxHost(environment: environment)
        #expect(try await host.handshake(sessionId: nil).connection?.localAppToken == first)
        try second.write(to: file, atomically: true, encoding: .utf8)
        #expect(try await host.handshake(sessionId: nil).connection?.localAppToken == second)
    }
}
