import Foundation
import Testing
@testable import CmuxCore

@Suite("SSH ProxyCommand local environment")
struct SSHProxyCommandEnvironmentTests {
    @Test("SSH child environment preserves the app environment and overlays only its agent socket", arguments: [nil, "/tmp/cmux-test-ssh-agent.sock"] as [String?])
    func preservesInheritedEnvironment(agentSocketPath: String?) {
        var expected = ProcessInfo.processInfo.environment
        if let agentSocketPath {
            expected["SSH_AUTH_SOCK"] = agentSocketPath
        }
        // Report only equality, never dump inherited credentials on failure.
        let preservesEnvironment = configuration(agentSocketPath: agentSocketPath).sshProcessEnvironment == expected
        #expect(preservesEnvironment)
    }

    @Test("A real OpenSSH ProxyCommand inherits local user context", arguments: [nil, "/tmp/cmux-test-ssh-agent.sock"] as [String?])
    func proxyCommandReceivesUserContext(agentSocketPath: String?) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-proxy-env-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let capture = directory.appendingPathComponent("context.txt")
        let proxy = directory.appendingPathComponent("proxy.sh")
        try """
        #!/bin/sh
        printf '%s\\n' "$HOME" "$USER" "$LOGNAME" "$PATH" "${SSH_AUTH_SOCK-unset}" > \(shellQuote(capture.path))
        exit 1
        """.write(to: proxy, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = [
            "-F", "/dev/null", "-o", "BatchMode=yes", "-o", "ConnectTimeout=2",
            "-o", "ProxyCommand=/bin/sh \(shellQuote(proxy.path))",
            "--", "cmux-proxy-environment.invalid",
        ]
        process.environment = configuration(agentSocketPath: agentSocketPath).sshProcessEnvironment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()

        // The helper intentionally ends before any SSH handshake or network connection.
        #expect(process.terminationStatus == 255)
        let inherited = ProcessInfo.processInfo.environment
        let expected = ["HOME", "USER", "LOGNAME", "PATH"].map { inherited[$0] ?? "" }
            + [agentSocketPath ?? inherited["SSH_AUTH_SOCK"] ?? "unset"]
        #expect(try String(contentsOf: capture, encoding: .utf8) == expected.joined(separator: "\n") + "\n")
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    private func configuration(agentSocketPath: String?) -> WorkspaceRemoteConfiguration {
        WorkspaceRemoteConfiguration(
            destination: "cmux-proxy-environment.invalid",
            port: nil,
            identityFile: nil,
            sshOptions: [],
            localProxyPort: nil,
            relayPort: nil,
            relayID: nil,
            relayToken: nil,
            localSocketPath: nil,
            terminalStartupCommand: nil,
            agentSocketPath: agentSocketPath
        )
    }
}
