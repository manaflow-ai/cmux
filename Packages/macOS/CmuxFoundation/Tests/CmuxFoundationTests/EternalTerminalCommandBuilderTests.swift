import Foundation
import Testing
@testable import CmuxFoundation

@Suite("Eternal Terminal command selection and fallback")
struct EternalTerminalCommandBuilderTests {
    @Test("falls back to SSH when et is missing locally")
    func localMissingFallsBack() throws {
        try withFakeCommands(installEternalTerminal: false) { directory, environment in
            let result = try run(
                builder(sshFallbackCommand: "printf 'ssh fallback\\n'", localExecutableName: "cmux-missing-et"),
                environment: environment
            )

            #expect(result.status == 0)
            #expect(result.stdout == "ssh fallback\n")
            #expect(result.stderr == "local et missing\n")
            #expect(!fileExists(directory, "ssh.args"))
        }
    }

    @Test("distinguishes a missing remote etterminal from other probe failures")
    func remoteMissingFallsBack() throws {
        try withFakeCommands(sshStatus: 127) { directory, environment in
            let result = try run(builder(sshFallbackCommand: "printf 'ssh fallback\\n'"), environment: environment)

            #expect(result.stdout == "ssh fallback\n")
            #expect(result.stderr == "remote etterminal missing\n")
            #expect(!fileExists(directory, "et.args"))
        }
    }

    @Test("uses the generic SSH fallback when the remote probe cannot complete")
    func remoteProbeFailureFallsBack() throws {
        try withFakeCommands(sshStatus: 255) { directory, environment in
            let result = try run(builder(sshFallbackCommand: "printf 'ssh fallback\\n'"), environment: environment)

            #expect(result.stdout == "ssh fallback\n")
            #expect(result.stderr == "remote probe failed\n")
            #expect(!fileExists(directory, "et.args"))
        }
    }

    @Test("falls back when etserver does not accept connections on the SSH-resolved host")
    func unreachableServerFallsBack() throws {
        try withFakeCommands(serverReachable: false) { directory, environment in
            let result = try run(
                builder(
                    sshFallbackCommand: "printf 'ssh fallback\\n'",
                    options: try #require(EternalTerminalOptions(serverPort: 2400))
                ),
                environment: environment
            )

            #expect(result.stdout == "ssh fallback\n")
            #expect(result.stderr == "etserver unreachable\n")
            #expect(try lines(directory, "nc.args") == ["-z", "-G", "5", "-w", "5", "resolved.example.com", "2400"])
            #expect(!fileExists(directory, "et.args"))
        }
    }

    @Test("finds etterminal outside the remote non-interactive PATH")
    func remoteTerminalOutsidePathIsResolved() throws {
        try withFakeCommands(executeRemoteCommand: true, installRemoteTerminal: .userLocalBin) { directory, environment in
            let result = try run(builder(), environment: environment)

            #expect(result.status == 0)
            #expect(result.stderr.isEmpty)
            // ET's own SSH hop only searches the non-interactive PATH, so the
            // probed location must reach et as --terminal-path.
            let arguments = try lines(directory, "et.args")
            let resolvedPath = directory.appendingPathComponent("remote-home/.local/bin/etterminal").path
            #expect(Array(arguments.prefix(2)) == ["--terminal-path", resolvedPath])
        }
    }

    @Test("treats probe output that is not an absolute path as a failed probe")
    func nonAbsoluteProbeOutputFallsBack() throws {
        try withFakeCommands(remoteTerminalPath: "etterminal") { directory, environment in
            let result = try run(builder(sshFallbackCommand: "printf 'ssh fallback\\n'"), environment: environment)

            #expect(result.stdout == "ssh fallback\n")
            #expect(result.stderr == "remote probe failed\n")
            #expect(!fileExists(directory, "et.args"))
        }
    }

    @Test("leaves etserver reachability to ET behind a ProxyJump host")
    func proxyJumpSkipsServerProbe() throws {
        try withFakeCommands(serverReachable: false, proxyJump: "bastion") { directory, environment in
            let result = try run(builder(), environment: environment)

            #expect(result.status == 0)
            #expect(result.stderr.isEmpty)
            #expect(!fileExists(directory, "nc.args"))
            #expect(fileExists(directory, "et.args"))
        }
    }

    @Test("probes an explicit --terminal-path instead of searching PATH")
    func explicitTerminalPathIsProbed() throws {
        try withFakeCommands(executeRemoteCommand: true, installRemoteTerminal: .custom) { directory, environment in
            let customPath = directory.appendingPathComponent("remote-home/opt/et/etterminal").path
            let found = try run(
                builder(options: try #require(EternalTerminalOptions(terminalPath: customPath))),
                environment: environment
            )
            #expect(found.stderr.isEmpty)
            #expect(try lines(directory, "et.args").contains(customPath))

            let missing = try run(
                builder(
                    sshFallbackCommand: "printf 'ssh fallback\\n'",
                    options: try #require(EternalTerminalOptions(terminalPath: customPath + "-missing"))
                ),
                environment: environment
            )
            #expect(missing.stdout == "ssh fallback\n")
            #expect(missing.stderr == "remote etterminal missing\n")
        }
    }

    @Test("single-quotes a terminal path that ET splices into its remote shell")
    func terminalPathWithSpaceIsQuotedForEternalTerminal() throws {
        try withFakeCommands(executeRemoteCommand: true, installRemoteTerminal: .customWithSpace) { directory, environment in
            let customPath = directory.appendingPathComponent("remote-home/opt/et tools/etterminal").path
            let result = try run(
                builder(options: try #require(EternalTerminalOptions(terminalPath: customPath))),
                environment: environment
            )

            #expect(result.stderr.isEmpty)
            #expect(Array(try lines(directory, "et.args").prefix(2)) == ["--terminal-path", "'\(customPath)'"])
        }
    }

    @Test("passes ET options, SSH options, agent forwarding and the remote command to et")
    func supportedEternalTerminalPreservesArguments() throws {
        try withFakeCommands(remoteTerminalPath: "/opt/et/etterminal") { directory, environment in
            let options = try #require(EternalTerminalOptions(
                serverPort: 2400,
                terminalPath: "/opt/et/etterminal",
                tunnels: ["8080:80", "8443:443"],
                reverseTunnels: ["9090:90"]
            ))
            let result = try run(
                builder(options: options, forwardsSSHAgent: true, sshAgentSocketPath: "/tmp/agent.sock"),
                environment: environment
            )

            #expect(result.status == 0)
            // ET keeps only the last --tunnel, so repeated values are joined.
            #expect(try lines(directory, "et.args") == [
                "--terminal-path", "/opt/et/etterminal",
                "--port", "2400",
                "--tunnel", "8080:80,8443:443",
                "--reversetunnel", "9090:90",
                "--forward-ssh-agent",
                "--ssh-socket", "/tmp/agent.sock",
                "--ssh-option", "RemoteCommand=none",
                "--ssh-option", "Port=2222",
                "--command", "exec 'command' 'space arg' 'quote'\\''arg'",
                "--noexit",
                "user@example.com",
            ])
        }
    }

    @Test("opens a plain login shell without --command")
    func plainShellHasNoCommand() throws {
        try withFakeCommands { directory, environment in
            _ = try run(builder(remoteCommandArguments: []), environment: environment)

            let arguments = try lines(directory, "et.args")
            #expect(!arguments.contains("--command"))
            #expect(arguments.last == "user@example.com")
            #expect(Array(arguments.prefix(4)) == ["--terminal-path", "/usr/bin/etterminal", "--port", "2022"])
        }
    }

    @Test(
        "the injected command execs the staged bootstrap under a fish login shell",
        .enabled(if: EternalTerminalCommandBuilderTests.fishExecutablePath != nil)
    )
    func remoteCommandRunsUnderFish() throws {
        let fish = try #require(Self.fishExecutablePath)
        let builder = builder(remoteCommandArguments: ["/bin/sh", "-c", "printf '%s\\n' \"$0:$1\"", "first arg", "it's"])
        let command = try #require(builder.remoteShellCommand)
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: fish)
        process.arguments = ["-c", command]
        process.standardOutput = output
        try process.run()
        process.waitUntilExit()
        #expect(String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self) == "first arg:it's\n")
    }

    @Test("removes SSH-only launchers and registers the attempt before et starts")
    func launchersRemovedAndLifecycleRegistered() throws {
        try withFakeCommands { directory, environment in
            let launcher = directory.appendingPathComponent("cmux-ssh-startup.sh")
            try "exit 0\n".write(to: launcher, atomically: true, encoding: .utf8)
            let result = try run(
                builder(remoteRelayPort: 64_007, sshFallbackLauncherPaths: [launcher.path]),
                environment: environment
            )
            let lifecycleCalls = try String(contentsOf: directory.appendingPathComponent("cmux.args"), encoding: .utf8)

            #expect(result.status == 0)
            #expect(!FileManager.default.fileExists(atPath: launcher.path))
            #expect(lifecycleCalls.contains("rpc workspace.remote.terminal_session_launching"))
            #expect(!lifecycleCalls.contains("rpc workspace.remote.terminal_session_connected"))
        }
    }

    @Test("falls back immediately when lifecycle registration fails")
    func lifecycleFailureFallsBack() throws {
        try withFakeCommands(lifecycleStatus: 1) { directory, environment in
            let launcher = directory.appendingPathComponent("cmux-ssh-startup.sh")
            try "exit 0\n".write(to: launcher, atomically: true, encoding: .utf8)
            let result = try run(
                builder(
                    sshFallbackCommand: "printf 'ssh fallback\\n'",
                    remoteRelayPort: 64_007,
                    sshFallbackLauncherPaths: [launcher.path]
                ),
                environment: environment
            )

            #expect(result.stdout == "ssh fallback\n")
            #expect(try lines(directory, "cmux.args").count == 1)
            #expect(fileExists(directory, "cmux-ssh-startup.sh"))
            #expect(!fileExists(directory, "et.args"))
        }
    }

    @Test("preserves SSH routing and agent opt-outs through SSH fallback", arguments: [
        "HostName=actual.example", "ProxyJump=bastion", "ProxyCommand=nc %h %p", "ForwardAgent=no",
    ])
    func unsupportedSSHOverridesFallBack(option: String) throws {
        try withFakeCommands { directory, environment in
            let result = try run(
                builder(sshFallbackCommand: "printf 'ssh fallback\\n'", sessionSSHOptions: [option]),
                environment: environment
            )

            #expect(result.stdout == "ssh fallback\n")
            #expect(result.stderr == "remote probe failed\n")
            #expect(!fileExists(directory, "et.args"))
        }
    }

    @Test("joins socket, environment, port and range tunnel entries independently")
    func repeatedTunnelGrammar() throws {
        for tunnels in [
            ["SERVICE_SOCK:/tmp/service.sock", "5037:5037"],
            ["/tmp/local.sock:/tmp/remote.sock", "5037:5037"],
            ["/tmp/local.sock:5037", "5038:/tmp/remote.sock"],
            ["8080:80,8443:443", "9090:90"],
            ["3000-3002:4000-4002", "5037:5037"],
        ] {
            let options = try #require(EternalTerminalOptions(tunnels: tunnels, reverseTunnels: tunnels))
            #expect(options.clientArguments == [
                "--port", "2022", "--tunnel", tunnels.joined(separator: ","),
                "--reversetunnel", tunnels.joined(separator: ","),
            ])
            #expect(try JSONDecoder().decode(EternalTerminalOptions.self, from: JSONEncoder().encode(options)) == options)
        }
        for tunnel in ["3000-3002:4000", "3000:4000-4002", "3000-3002:4000-4003"] {
            #expect(EternalTerminalOptions(tunnels: [tunnel, "5037:5037"]) == nil)
            #expect(EternalTerminalOptions(reverseTunnels: [tunnel, "5037:5037"]) == nil)
            #expect(EternalTerminalOptions(tunnels: [tunnel + ",5037:5037"]) == nil)
        }
    }

    @Test("maps the management ssh argv onto et --ssh-option values")
    func sessionSSHOptionsFromArguments() {
        #expect(EternalTerminalCommandBuilder.sessionSSHOptions(fromSSHArguments: [
            "/usr/bin/ssh", "-o", "RemoteCommand=none", "-p", "2222", "-i", "/keys/id",
            "-o", "ControlPath=/tmp/cm-%C", "-o", "RequestTTY=no", "-T",
        ]) == ["RemoteCommand=none", "Port=2222", "IdentityFile=/keys/id", "ControlPath=/tmp/cm-%C"])
        #expect(EternalTerminalCommandBuilder.sessionSSHOptions(fromSSHArguments: [
            "/usr/bin/ssh", "-i", "/keys/id with space",
        ]) == [#"IdentityFile="/keys/id with space""#])
    }

    @Test("forwards the agent only for an effective ForwardAgent request")
    func forwardsAgent() {
        #expect(!EternalTerminalCommandBuilder.forwardsSSHAgent(sshOptions: []))
        #expect(!EternalTerminalCommandBuilder.forwardsSSHAgent(sshOptions: ["ForwardAgent=no"]))
        #expect(EternalTerminalCommandBuilder.forwardsSSHAgent(sshOptions: ["ForwardAgent=/tmp/agent.sock"]))
    }

    @Test("validates and round-trips ET options")
    func optionsValidation() throws {
        #expect(EternalTerminalOptions(serverPort: 0) == nil)
        #expect(EternalTerminalOptions(serverPort: 65_536) == nil)
        #expect(EternalTerminalOptions(terminalPath: " ") == nil)
        #expect(EternalTerminalOptions(terminalPath: "~/bin/etterminal") == nil)
        #expect(EternalTerminalOptions(terminalPath: "bin/etterminal") == nil)
        // Repeated tunnels are comma-joined, which ET parses only as port:port.
        #expect(EternalTerminalOptions(tunnels: ["localhost:2222:db.internal:22"]) != nil)
        #expect(EternalTerminalOptions(tunnels: ["localhost:2222:db.internal:22", "8080:80"]) == nil)
        #expect(EternalTerminalOptions(reverseTunnels: ["9090:90", "x:90"]) == nil)
        #expect(EternalTerminalOptions(tunnels: ["8080:80", "9000-9003:9000-9003"])?.tunnels.count == 2)
        #expect(EternalTerminalOptions(tunnels: ["80\n:80"]) == nil)
        #expect(EternalTerminalOptions(tunnels: [" 80:80\n"])?.tunnels == ["80:80"])
        #expect(EternalTerminalOptions.default.clientArguments == ["--port", "2022"])

        let options = try #require(EternalTerminalOptions(serverPort: 2400, terminalPath: "/opt/et", tunnels: ["1:2"]))
        let data = try JSONEncoder().encode(options)
        #expect(try JSONDecoder().decode(EternalTerminalOptions.self, from: data) == options)
        #expect(try JSONDecoder().decode(EternalTerminalOptions.self, from: Data("{}".utf8)) == .default)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(EternalTerminalOptions.self, from: Data(#"{"serverPort":0}"#.utf8))
        }
        #expect(WorkspaceRemoteTerminalTransport(cliValue: " ET ") == .et)
    }

    // MARK: - Fixtures

    enum RemoteTerminalInstall {
        case none
        case userLocalBin
        case custom
        case customWithSpace
    }

    private func builder(
        sshFallbackCommand: String = "exit 90",
        options: EternalTerminalOptions = .default,
        forwardsSSHAgent: Bool = false,
        sshAgentSocketPath: String? = nil,
        remoteCommandArguments: [String] = ["command", "space arg", "quote'arg"],
        remoteRelayPort: Int? = nil,
        sshFallbackLauncherPaths: [String] = [],
        localExecutableName: String = "et",
        sessionSSHOptions: [String] = ["RemoteCommand=none", "Port=2222"]
    ) -> EternalTerminalCommandBuilder {
        EternalTerminalCommandBuilder(
            capabilityProbeSSHArguments: ["ssh", "-o", "RemoteCommand=none"],
            sessionSSHOptions: sessionSSHOptions,
            localEternalTerminalExecutableName: localExecutableName,
            localServerProbeExecutableName: "nc",
            destination: "user@example.com",
            options: options,
            forwardsSSHAgent: forwardsSSHAgent,
            sshAgentSocketPath: sshAgentSocketPath,
            remoteCommandArguments: remoteCommandArguments,
            remoteRelayPort: remoteRelayPort,
            sshFallbackCommand: sshFallbackCommand,
            sshFallbackLauncherPaths: sshFallbackLauncherPaths,
            messages: .init(
                localMissing: "local et missing",
                remoteMissing: "remote etterminal missing",
                remoteProbeFailed: "remote probe failed",
                serverUnreachable: "etserver unreachable",
                remoteBootstrapInstallFailed: "remote bootstrap install failed"
            )
        )
    }

    private static var fishExecutablePath: String? {
        ["/opt/homebrew/bin/fish", "/usr/local/bin/fish", "/usr/bin/fish"]
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) })
    }

    private func withFakeCommands(
        sshStatus: Int32 = 0,
        installEternalTerminal: Bool = true,
        serverReachable: Bool = true,
        executeRemoteCommand: Bool = false,
        installRemoteTerminal: RemoteTerminalInstall = .none,
        remoteTerminalPath: String = "/usr/bin/etterminal",
        proxyJump: String? = nil,
        lifecycleStatus: Int32 = 0,
        operation: (URL, [String: String]) throws -> Void
    ) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-et-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        try installExecutable(named: "ssh", script: """
            #!/bin/sh
            printf '%s\\n' "$@" >> "$SSH_ARGS_FILE"
            for cmux_arg in "$@"; do
              if [ "$cmux_arg" = "-G" ]; then
                printf '%s\\n' 'user user' 'hostname resolved.example.com' 'port 22'
                if [ -n "$FAKE_PROXY_JUMP" ]; then printf 'proxyjump %s\\n' "$FAKE_PROXY_JUMP"; fi
                exit 0
              fi
            done
            cmux_remote_command=
            for cmux_arg in "$@"; do cmux_remote_command=$cmux_arg; done
            if [ "$FAKE_SSH_EXEC_REMOTE" = "1" ]; then
              HOME="$FAKE_REMOTE_HOME" PATH=/usr/bin:/bin /bin/sh -c "$cmux_remote_command"
              exit $?
            fi
            if [ "$FAKE_SSH_STATUS" = "0" ]; then
              printf '%s\\n' 'remote shell startup noise' "$FAKE_REMOTE_TERMINAL_PATH"
            fi
            exit "$FAKE_SSH_STATUS"
            """, in: directory)
        try installExecutable(named: "nc", script: """
            #!/bin/sh
            printf '%s\\n' "$@" > "$NC_ARGS_FILE"
            exit "$FAKE_NC_STATUS"
            """, in: directory)
        try installExecutable(named: "cmux", script: """
            #!/bin/sh
            printf '%s\\n' "$*" >> "$CMUX_ARGS_FILE"
            exit "$FAKE_LIFECYCLE_STATUS"
            """, in: directory)
        if installEternalTerminal {
            try installExecutable(named: "et", script: """
                #!/bin/sh
                printf '%s\\n' "$@" > "$ET_ARGS_FILE"
                exit 0
                """, in: directory)
        }
        let remoteHome = directory.appendingPathComponent("remote-home", isDirectory: true)
        let remoteTerminalDirectory: String? = switch installRemoteTerminal {
        case .none: nil
        case .userLocalBin: ".local/bin"
        case .custom: "opt/et"
        case .customWithSpace: "opt/et tools"
        }
        if let remoteTerminalDirectory {
            let remoteBin = remoteHome.appendingPathComponent(remoteTerminalDirectory, isDirectory: true)
            try FileManager.default.createDirectory(at: remoteBin, withIntermediateDirectories: true)
            try installExecutable(named: "etterminal", script: "#!/bin/sh\nexit 0\n", in: remoteBin)
        }
        try operation(directory, [
            "PATH": directory.path + ":/usr/bin:/bin",
            "FAKE_SSH_STATUS": String(sshStatus),
            "FAKE_SSH_EXEC_REMOTE": executeRemoteCommand ? "1" : "0",
            "FAKE_REMOTE_HOME": remoteHome.path,
            "FAKE_REMOTE_TERMINAL_PATH": remoteTerminalPath,
            "FAKE_PROXY_JUMP": proxyJump ?? "",
            "FAKE_LIFECYCLE_STATUS": String(lifecycleStatus),
            "FAKE_NC_STATUS": serverReachable ? "0" : "1",
            "SSH_ARGS_FILE": directory.appendingPathComponent("ssh.args").path,
            "NC_ARGS_FILE": directory.appendingPathComponent("nc.args").path,
            "ET_ARGS_FILE": directory.appendingPathComponent("et.args").path,
            "CMUX_ARGS_FILE": directory.appendingPathComponent("cmux.args").path,
            "CMUX_BUNDLED_CLI_PATH": directory.appendingPathComponent("cmux").path,
            "CMUX_SOCKET_PATH": "/tmp/cmux-et-test.sock",
            "CMUX_WORKSPACE_ID": "11111111-1111-1111-1111-111111111111",
            "CMUX_SURFACE_ID": "22222222-2222-2222-2222-222222222222",
            "CMUX_TERMINAL_LIFECYCLE_ID": "33333333-3333-3333-3333-333333333333",
        ])
    }

    private func fileExists(_ directory: URL, _ name: String) -> Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path)
    }

    private func lines(_ directory: URL, _ name: String) throws -> [String] {
        try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .dropLast()
            .map(String.init)
    }

    private func installExecutable(named name: String, script: String, in directory: URL) throws {
        let url = directory.appendingPathComponent(name)
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func run(
        _ builder: EternalTerminalCommandBuilder,
        environment: [String: String]
    ) throws -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", builder.command()]
        process.environment = environment
        process.standardOutput = standardOutput
        process.standardError = standardError
        try process.run()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            String(decoding: standardOutput.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
            String(decoding: standardError.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        )
    }
}
