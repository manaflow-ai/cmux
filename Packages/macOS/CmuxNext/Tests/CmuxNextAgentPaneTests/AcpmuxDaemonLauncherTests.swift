import Foundation
import Testing
@testable import CmuxNextAgentPane

/// Runs the real spawn path against a stand-in `acpmux` script.
@Suite struct AcpmuxDaemonLauncherTests {
    private func environment(script: String) throws -> (AcpmuxEnvironment, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agent-pane-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let executable = root.appendingPathComponent("acpmux")
        try ("#!/bin/sh\n" + script).write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let socket = root.appendingPathComponent("a.sock").path
        return (AcpmuxEnvironment(executable: executable, home: home, socketPath: socket, daemonArguments: ["--listen", "127.0.0.1:0"],
                                  childEnvironment: ["ACPMUX_HOME": home.path, "ACPMUX_SOCKET": socket]), root)
    }

    @Test func readsTheEndpointFromTheReadyLine() async throws {
        // Echoes its arguments to the log and reports ready on fd 3.
        let (environment, root) = try environment(script: #"""
        echo "$@"
        printf '{"ready":true,"pid":%s,"webUrl":"http://127.0.0.1:5123/?token=tok"}\n' "$$" >&3
        """#)
        defer { try? FileManager.default.removeItem(at: root) }
        let endpoint = try await AcpmuxDaemonLauncher.launch(environment, deadline: .seconds(10))
        #expect(endpoint == AcpmuxWebEndpoint(url: URL(string: "ws://127.0.0.1:5123/")!, token: "tok"))
        let log = try String(contentsOfFile: environment.logPath, encoding: .utf8)
        #expect(log.contains("daemon run --ready-fd 3 --listen 127.0.0.1:0"))
    }

    @Test func aDaemonThatExitsEarlyIsReportedWithItsLog() async throws {
        let (environment, root) = try environment(script: "echo 'error: address in use' >&2\nexit 1\n")
        defer { try? FileManager.default.removeItem(at: root) }
        await #expect(throws: AcpmuxDaemonLauncher.Failure.exited(logPath: environment.logPath)) {
            try await AcpmuxDaemonLauncher.launch(environment, deadline: .seconds(10))
        }
        #expect(try String(contentsOfFile: environment.logPath, encoding: .utf8).contains("address in use"))
    }

    @Test func aReadyLineWithoutAWebSocketIsAFailure() async throws {
        let (environment, root) = try environment(script: #"printf '{"ready":true}\n' >&3"# + "\n")
        defer { try? FileManager.default.removeItem(at: root) }
        await #expect(throws: AcpmuxDaemonLauncher.Failure.noWebSocket(logPath: environment.logPath)) {
            try await AcpmuxDaemonLauncher.launch(environment, deadline: .seconds(10))
        }
    }

    @Test func aSilentDaemonMissesTheDeadline() async throws {
        let (environment, root) = try environment(script: "sleep 2\n")
        defer { try? FileManager.default.removeItem(at: root) }
        await #expect(throws: AgentPaneDeadlineExceeded.self) {
            try await AcpmuxDaemonLauncher.launch(environment, deadline: .milliseconds(300))
        }
    }
}
