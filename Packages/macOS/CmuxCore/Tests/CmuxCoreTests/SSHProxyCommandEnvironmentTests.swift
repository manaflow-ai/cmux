import Foundation
import Testing
@testable import CmuxCore

@Suite("SSH ProxyCommand local environment")
struct SSHProxyCommandEnvironmentTests {
    @Test(
        "SSH child environment preserves the app environment and overlays only its agent socket",
        arguments: [nil, "", "/tmp/cmux-test-ssh-agent.sock"] as [String?]
    )
    /// Verifies that an absent override inherits all caller variables while a
    /// usable override replaces only `SSH_AUTH_SOCK`.
    func preservesInheritedEnvironment(agentSocketPath: String?) {
        var expected = ProcessInfo.processInfo.environment
        if let agentSocketPath {
            expected["SSH_AUTH_SOCK"] = agentSocketPath.isEmpty ? nil : agentSocketPath
        }
        // Report only equality, never dump inherited credentials on failure.
        let preservesEnvironment = configuration(agentSocketPath: agentSocketPath).sshProcessEnvironment == expected
        #expect(preservesEnvironment)
    }

    @Test("SSH child environment removes an explicitly disabled agent socket")
    /// Verifies that an explicit empty agent override suppresses the inherited
    /// socket without exposing its value in test output.
    func removesExplicitlyDisabledAgentSocket() {
        var expected = ProcessInfo.processInfo.environment
        expected.removeValue(forKey: "SSH_AUTH_SOCK")
        let matches = configuration(agentSocketPath: "").sshProcessEnvironment == expected
        #expect(matches)
    }

    @Test(
        "A real OpenSSH ProxyCommand inherits the local user context",
        arguments: [nil, "", "/tmp/cmux-test-ssh-agent.sock"] as [String?]
    )
    /// Runs OpenSSH with a local helper and checks only the expected inherited
    /// context, keeping credentials and command details out of failures.
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
        // OpenSSH executes ProxyCommand through $SHELL. A runner's zshenv can
        // rewrite PATH before our helper starts, so control the shell and all
        // fixture values instead of asserting on the runner's private context.
        let inherited = [
            "HOME": directory.path,
            "USER": "cmux-proxy-test",
            "LOGNAME": "cmux-proxy-test",
            "PATH": "/cmux-proxy-fixture/bin:/usr/bin:/bin",
            "SHELL": "/bin/sh",
            "SSH_AUTH_SOCK": "/tmp/cmux-inherited-test-agent.sock",
        ]
        process.environment = configuration(agentSocketPath: agentSocketPath)
            .sshProcessEnvironment(inheriting: inherited)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()

        // The helper intentionally ends before any SSH handshake or network connection.
        #expect(process.terminationStatus == 255)
        let expected = ["HOME", "USER", "LOGNAME", "PATH"].map { inherited[$0] ?? "" }
            + [agentSocketPath.map { $0.isEmpty ? "unset" : $0 } ?? inherited["SSH_AUTH_SOCK"] ?? "unset"]
        let proxyReceivedExpectedEnvironment =
            try String(contentsOf: capture, encoding: .utf8) == expected.joined(separator: "\n") + "\n"
        // Report only equality, never dump inherited credentials on failure.
        #expect(proxyReceivedExpectedEnvironment)
    }

    /// Copies must retain a disabled override after its raw empty string is normalized.
    @Test("Configuration copies keep an explicitly disabled agent")
    func copiesKeepDisabledAgent() {
        let original = configuration(agentSocketPath: "")
        let copies = [original.scopedToOwnerWorkspace(UUID()), original.withDaemonWebSocketEndpoint(nil),
                      original.withSSHControlMasterLeaseGeneration(UUID())]
        for copy in copies {
            let noAgent = copy.sshProcessEnvironment?["SSH_AUTH_SOCK"] == nil
            #expect(noAgent)
        }
    }

    /// Quotes one temporary path for the shell script used by the test.
    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    /// Builds the smallest remote configuration needed by the environment
    /// assertions.
    private func configuration(
        agentSocketPath: String?
    ) -> WorkspaceRemoteConfiguration {
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
