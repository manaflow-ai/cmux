import CmuxCloud
import CmuxCore
import CmuxFoundation
import Foundation
import Testing

@Suite("SSH carrier agent option precedence")
struct SSHTuiAgentOptionsTests {
    @Test("Auth, preflight, carrier and browser share the marked agent route")
    func markedRouteUsesOneControlPathAcrossLaunches() throws {
        let routeIdentifier = String(repeating: "d", count: 64)
        let connection = connection(
            agent: "/tmp/cmux-route-agent.sock",
            options: ["ProxyCommand=/bin/sh -c true", "__cmux_route_sensitive=\(routeIdentifier)"],
            environment: ["PATH": "/usr/bin", "SSH_AUTH_SOCK": "/tmp/cmux-route-agent.sock"]
        )
        let paths = sshInvocations(connection).compactMap { arguments in
            arguments.first { $0.hasPrefix("ControlPath=") }
        }
        #expect(paths.count == 4)
        #expect(Set(paths).count == 1)
    }

    @Test("A restored cmux carrier keeps its saved route socket with an agent")
    func restoredCmuxCarrierKeepsSavedControlPath() throws {
        let socketDirectory = try #require(SSHConnectionSharingOptions().controlSocketDirectoryPath)
        let savedPath = socketDirectory + "/" + String(repeating: "b", count: 40)
        var snapshot = SessionRemoteWorkspaceSnapshot(
            transport: .ssh,
            destination: "example.invalid",
            sshOptions: ["ControlPath=\(savedPath)"],
            agentSocketPath: "/tmp/cmux-saved-agent.sock",
            preserveAfterTerminalExit: true
        )
        snapshot.sshSessionOwner = "cmux-tui"
        var configuration = WorkspaceRemoteConfiguration(
            destination: "example.invalid", port: nil, identityFile: nil,
            sshOptions: ["ControlPath=\(savedPath)"],
            localProxyPort: nil, relayPort: nil, relayID: nil, relayToken: nil,
            localSocketPath: nil, terminalStartupCommand: nil,
            agentSocketPath: "/tmp/cmux-saved-agent.sock",
            preserveAfterTerminalExit: true
        )
        configuration.restoredSSHSession = snapshot

        let connection = SSHTuiConnection(
            configuration: configuration,
            environment: ["PATH": "/usr/bin", "SSH_AUTH_SOCK": "/tmp/cmux-saved-agent.sock"]
        )
        #expect(connection.authenticationArguments.contains("ControlPath=\(savedPath)"))
    }

    @Test("A forwarded socket preserves the user's IdentityAgent", arguments: [false, true])
    func forwardedSocketPreservesIdentityAgent(explicitOption: Bool) throws {
        let connection = connection(
            agent: "/tmp/cmux-caller-environment.sock",
            options: explicitOption ? ["IdentityAgent=/tmp/cmux-option-agent.sock"] : []
        )
        let expected = explicitOption ? "/tmp/cmux-option-agent.sock" : "/tmp/cmux-config-agent.sock"
        for arguments in sshInvocations(connection) {
            #expect(try resolvedIdentityAgent(arguments) == expected)
        }
    }

    @Test("Explicit disable preserves IdentityAgent in options and SSH config", arguments: [false, true])
    func disabledSocketPreservesIdentityAgent(explicitOption: Bool) throws {
        let connection = connection(
            agent: "",
            options: explicitOption ? ["IdentityAgent=/tmp/cmux-option-agent.sock"] : []
        )
        for arguments in sshInvocations(connection) {
            let expected = explicitOption ? "/tmp/cmux-option-agent.sock" : "/tmp/cmux-config-agent.sock"
            #expect(try resolvedIdentityAgent(arguments) == expected)
        }
    }

    /// Builds the same socket override the CLI sends to the app.
    private func connection(
        agent: String,
        options: [String],
        environment: [String: String] = [:]
    ) -> SSHTuiConnection {
        SSHTuiConnection(configuration: WorkspaceRemoteConfiguration(
            destination: "example.invalid", port: nil, identityFile: nil, sshOptions: options,
            localProxyPort: nil, relayPort: nil, relayID: nil, relayToken: nil, localSocketPath: nil,
            terminalStartupCommand: nil, agentSocketPath: agent
        ), environment: environment)
    }

    /// Exercises interactive authentication, batch preflight, carrier and browser launches.
    private func sshInvocations(_ connection: SSHTuiConnection) -> [[String]] {
        let carriers = [
            connection.arguments(stateDirectory: "/tmp/cmux-test", deviceName: "test"),
            connection.browserArguments(stateDirectory: "/tmp/cmux-test")
        ].map { arguments in
            arguments.indices.compactMap { index -> String? in
                guard index > 0, arguments[index - 1] == "--ssh-arg" else { return nil }
                return arguments[index]
            } + [connection.configuration.destination]
        }
        return [Array(connection.authenticationArguments.dropFirst()),
                Array(connection.preflightArguments.dropFirst())] + carriers
    }

    /// Asks system OpenSSH to resolve our isolated configuration without opening a connection.
    private func resolvedIdentityAgent(_ arguments: [String]) throws -> String? {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = directory.appendingPathComponent("config")
        try "Host *\n  IdentityAgent /tmp/cmux-config-agent.sock\n".write(to: config, atomically: true, encoding: .utf8)
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = ["-G", "-F", config.path] + arguments
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0)
        return String(decoding: data, as: UTF8.self).split(separator: "\n")
            .first { $0.hasPrefix("identityagent ") }
            .map { String($0.dropFirst("identityagent ".count)) }
    }
}
