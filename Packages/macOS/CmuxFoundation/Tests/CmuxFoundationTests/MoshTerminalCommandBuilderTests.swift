import Foundation
import Testing
@testable import CmuxFoundation

@Suite("Mosh terminal command selection and fallback")
struct MoshTerminalCommandBuilderTests {
    @Test("falls back to SSH when Mosh is missing locally")
    func localMoshMissingFallsBack() throws {
        try withFakeCommands(sshStatus: 0, installMosh: false) { directory, environment in
            let result = try run(
                builder(
                    sshFallbackCommand: "printf 'ssh fallback\\n'",
                    localMoshExecutableName: "cmux-missing-mosh"
                ),
                environment: environment
            )

            #expect(result.status == 0)
            #expect(result.stdout == "ssh fallback\n")
            #expect(result.stderr == "local mosh missing\n")
            #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("ssh.args").path))
        }
    }

    @Test("falls back to SSH when local Mosh lacks remote-IP support")
    func incompatibleLocalMoshFallsBack() throws {
        try withFakeCommands(sshStatus: 0, moshSupportsRemoteIP: false) { _, environment in
            let result = try run(
                builder(sshFallbackCommand: "printf 'ssh fallback\\n'"),
                environment: environment
            )

            #expect(result.status == 0)
            #expect(result.stdout == "ssh fallback\n")
            #expect(result.stderr == "local mosh unsupported\n")
        }
    }

    @Test("distinguishes a missing remote mosh-server from other probe failures")
    func remoteMoshMissingFallsBack() throws {
        try withFakeCommands(sshStatus: 127) { directory, environment in
            let result = try run(
                builder(sshFallbackCommand: "printf 'ssh fallback\\n'"),
                environment: environment
            )

            #expect(result.status == 0)
            #expect(result.stdout == "ssh fallback\n")
            #expect(result.stderr == "remote mosh missing\n")
            #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("mosh.args").path))
        }
    }

    @Test("uses the generic SSH fallback when the remote probe cannot complete")
    func remoteProbeFailureFallsBack() throws {
        try withFakeCommands(sshStatus: 255) { directory, environment in
            let result = try run(
                builder(sshFallbackCommand: "printf 'ssh fallback\\n'"),
                environment: environment
            )

            #expect(result.status == 0)
            #expect(result.stdout == "ssh fallback\n")
            #expect(result.stderr == "remote probe failed\n")
            #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("mosh.args").path))
        }
    }

    @Test("finds a remote mosh-server in a user-local bin directory outside PATH")
    func remoteMoshServerOutsidePathIsResolved() throws {
        try withFakeCommands(
            sshStatus: 0,
            executeRemoteCommand: true,
            installRemoteMoshServerOutsidePath: true
        ) { directory, environment in
            let result = try run(builder(), environment: environment)

            #expect(result.status == 0)
            #expect(result.stderr.isEmpty)
            #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("mosh.args").path))
        }
    }

    @Test(
        "runs remote probes through POSIX sh under a fish login shell",
        .enabled(if: MoshTerminalCommandBuilderTests.fishExecutablePath != nil)
    )
    func remoteProbeIsShellAgnostic() throws {
        let fishPath = try #require(Self.fishExecutablePath)
        try withFakeCommands(
            sshStatus: 0,
            executeRemoteCommand: true,
            installRemoteMoshServerOutsidePath: true,
            remoteLoginShell: fishPath
        ) { directory, environment in
            let remoteHome = directory.appendingPathComponent("remote-home", isDirectory: true)
            let staging = try #require(RemoteBootstrapStagingCommandBuilder(
                installerSSHArguments: ["ssh", "-o", "RemoteCommand=none"],
                destination: "user@example.com",
                remoteRelayPort: 52_263,
                bootstrapScript: "printf '%s\\n' fish-bootstrap"
            ))
            let result = try run(
                builder(
                    preparationShellScript: staging.preparationShellScript,
                    remoteRelayPort: 52_263
                ),
                environment: environment
            )

            #expect(result.status == 0)
            #expect(result.stdout.isEmpty)
            #expect(result.stderr.isEmpty)
            #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("mosh.args").path))
            #expect(FileManager.default.fileExists(
                atPath: remoteHome.appendingPathComponent(".cmux/relay/52263.bootstrap.sh").path
            ))
        }
    }

    @Test("preserves the Mosh SSH bootstrap and remote command argv")
    func supportedMoshPreservesArguments() throws {
        try withFakeCommands(sshStatus: 0) { directory, environment in
            let result = try run(builder(), environment: environment)
            let moshArguments = String(
                decoding: try Data(contentsOf: directory.appendingPathComponent("mosh.args")),
                as: UTF8.self
            ).split(separator: "\n", omittingEmptySubsequences: false).dropLast().map(String.init)
            let probeOutput = String(
                decoding: try Data(contentsOf: directory.appendingPathComponent("ssh.args")),
                as: UTF8.self
            )
            let probeInvocations = probeOutput
                .components(separatedBy: "__CMUX_SSH_INVOCATION_END__\n")
                .filter { !$0.isEmpty }
                .map { $0.split(separator: "\n").map(String.init) }
            let capabilityProbeArguments = try #require(
                probeInvocations.first(where: { $0.last?.contains("mosh-server") == true })
            )
            let probeArguments = try #require(probeInvocations.first)

            #expect(result.status == 0)
            #expect(result.stdout.isEmpty)
            #expect(result.stderr.isEmpty)
            #expect(Array(probeArguments.prefix(4)) == [
                "-o", "RemoteCommand=none", "-T", "user@example.com",
            ])
            #expect(capabilityProbeArguments.last?.contains("$HOME/.local/bin") == true)
            #expect(probeInvocations.contains(where: { $0.last?.contains("SSH_CONNECTION") == true }))
            #expect(moshArguments[0] == "--experimental-remote-ip=remote")
            #expect(moshArguments[1] == "--ssh='ssh' '-o' 'RemoteCommand=none' '-p' '2222'")
            #expect(moshArguments[2].hasPrefix("--server="))
            #expect(moshArguments[2].contains("mosh-server"))
            #expect(Array(moshArguments.suffix(5)) == [
                "--", "user@example.com", "command", "space arg", "quote'arg",
            ])
        }
    }

    @Test("keeps a large bootstrap preparation out of Mosh remote argv")
    func largePreparationIsNotRemoteArgv() throws {
        try withFakeCommands(sshStatus: 0) { directory, environment in
            let largePreparation = ": # " + String(repeating: "bootstrap", count: 20_000)
            let result = try run(
                builder(preparationShellScript: largePreparation),
                environment: environment
            )
            let moshArguments = try Data(
                contentsOf: directory.appendingPathComponent("mosh.args")
            )

            #expect(result.status == 0)
            #expect(moshArguments.count < 8_192)
        }
    }

    @Test("keeps a large SSH fallback within the local launcher argument budget")
    func largeFallbackIsEmbeddedOnce() throws {
        try withFakeCommands(sshStatus: 0, installMosh: false) { _, environment in
            let fallbackPadding = String(repeating: "x", count: 210_000)
            let fallbackCommand = "printf 'ssh fallback\\n'; : # \(fallbackPadding)"
            let command = builder(
                sshFallbackCommand: fallbackCommand,
                localMoshExecutableName: "cmux-missing-mosh"
            ).command()

            #expect(command.utf8.count < fallbackCommand.utf8.count * 2)
            let result = try run(
                builder(
                    sshFallbackCommand: fallbackCommand,
                    localMoshExecutableName: "cmux-missing-mosh"
                ),
                environment: environment
            )
            #expect(result.status == 0)
            #expect(result.stdout == "ssh fallback\n")
            #expect(result.stderr == "local mosh missing\n")
        }
    }

    @Test("falls back to SSH when remote preparation fails")
    func preparationFailureFallsBack() throws {
        try withFakeCommands(sshStatus: 0) { _, environment in
            let result = try run(
                builder(
                    sshFallbackCommand: "printf 'ssh fallback\\n'",
                    preparationShellScript: "printf '%s\\n' 'bootstrap install stderr' >&2; false"
                ),
                environment: environment
            )

            #expect(result.status == 0)
            #expect(result.stdout == "ssh fallback\n")
            #expect(result.stderr.contains("remote bootstrap install failed"))
            #expect(result.stderr.contains("bootstrap install stderr"))
            #expect(!result.stderr.contains("remote probe failed"))
        }
    }

    @Test("falls back to SSH proxy address resolution when SSH advertises an unusable address")
    func unusableRemoteAddressUsesProxyMode() throws {
        try withFakeCommands(
            sshStatus: 0,
            sshConnection: "0.0.0.0 0 0.0.0.0 0"
        ) { directory, environment in
            let result = try run(builder(), environment: environment)
            let moshArguments = try String(
                contentsOf: directory.appendingPathComponent("mosh.args"),
                encoding: .utf8
            )

            #expect(result.status == 0)
            #expect(moshArguments.firstLine == "--experimental-remote-ip=proxy")
            #expect(result.stderr.contains("mosh address fallback engaged"))
        }
    }

    @Test("falls back to SSH proxy address resolution when SSH_CONNECTION is empty")
    func emptyRemoteAddressUsesProxyMode() throws {
        try withFakeCommands(sshStatus: 0, sshConnection: "") { directory, environment in
            let result = try run(builder(), environment: environment)
            let moshArguments = try String(
                contentsOf: directory.appendingPathComponent("mosh.args"),
                encoding: .utf8
            )

            #expect(result.status == 0)
            #expect(moshArguments.firstLine == "--experimental-remote-ip=proxy")
            #expect(result.stderr.contains("mosh address fallback engaged"))
        }
    }

    @Test("falls back to SSH proxy address resolution when SSH advertises a loopback server address")
    func loopbackServerAddressUsesProxyMode() throws {
        try withFakeCommands(
            sshStatus: 0,
            sshConnection: "127.0.0.1 51675 127.0.0.1 22"
        ) { directory, environment in
            let result = try run(builder(), environment: environment)
            let moshArguments = try String(
                contentsOf: directory.appendingPathComponent("mosh.args"),
                encoding: .utf8
            )

            #expect(result.status == 0)
            #expect(moshArguments.firstLine == "--experimental-remote-ip=proxy")
            #expect(result.stderr.contains("mosh address fallback engaged"))
        }
    }

    @Test("falls back to SSH proxy address resolution when SSH_CONNECTION is truncated")
    func truncatedRemoteAddressUsesProxyMode() throws {
        try withFakeCommands(
            sshStatus: 0,
            sshConnection: "192.0.2.10 12345"
        ) { directory, environment in
            let result = try run(builder(), environment: environment)
            let moshArguments = try String(
                contentsOf: directory.appendingPathComponent("mosh.args"),
                encoding: .utf8
            )

            #expect(result.status == 0)
            #expect(moshArguments.firstLine == "--experimental-remote-ip=proxy")
            #expect(result.stderr.contains("mosh address fallback engaged"))
        }
    }

    @Test("falls back to SSH proxy address resolution when a port is non-numeric")
    func nonNumericPortUsesProxyMode() throws {
        try withFakeCommands(
            sshStatus: 0,
            sshConnection: "192.0.2.10 12345 192.0.2.20 ssh"
        ) { directory, environment in
            let result = try run(builder(), environment: environment)
            let moshArguments = try String(
                contentsOf: directory.appendingPathComponent("mosh.args"),
                encoding: .utf8
            )

            #expect(result.status == 0)
            #expect(moshArguments.firstLine == "--experimental-remote-ip=proxy")
            #expect(result.stderr.contains("mosh address fallback engaged"))
        }
    }

    @Test("falls back to SSH proxy address resolution when the SSH address probe fails")
    func addressProbeFailureUsesProxyMode() throws {
        try withFakeCommands(sshStatus: 0, sshConnectionStatus: 255) { directory, environment in
            let result = try run(builder(), environment: environment)
            let moshArguments = try String(
                contentsOf: directory.appendingPathComponent("mosh.args"),
                encoding: .utf8
            )

            #expect(result.status == 0)
            #expect(moshArguments.firstLine == "--experimental-remote-ip=proxy")
            #expect(result.stderr.contains("mosh address fallback engaged"))
        }
    }

    @Test("keeps remote address resolution when SSH advertises zero ports")
    func zeroRemotePortsKeepRemoteMode() throws {
        try withFakeCommands(
            sshStatus: 0,
            sshConnection: "192.0.2.10 0 192.0.2.20 0"
        ) { directory, environment in
            let result = try run(builder(), environment: environment)
            let moshArguments = try String(
                contentsOf: directory.appendingPathComponent("mosh.args"),
                encoding: .utf8
            )

            #expect(result.status == 0)
            #expect(moshArguments.firstLine == "--experimental-remote-ip=remote")
            #expect(result.stderr.isEmpty)
        }
    }

    @Test("keeps remote address resolution when only the peer address is unusual")
    func unusualPeerAddressKeepsRemoteMode() throws {
        try withFakeCommands(
            sshStatus: 0,
            sshConnection: "fe80::1%en0 51675 203.0.113.7 22"
        ) { directory, environment in
            let result = try run(builder(), environment: environment)
            let moshArguments = try String(
                contentsOf: directory.appendingPathComponent("mosh.args"),
                encoding: .utf8
            )

            #expect(result.status == 0)
            #expect(moshArguments.firstLine == "--experimental-remote-ip=remote")
            #expect(result.stderr.isEmpty)
        }
    }

    @Test("honors an explicit local Mosh address mode")
    func explicitLocalMode() throws {
        try withFakeCommands(sshStatus: 0) { directory, environment in
            let result = try run(
                builder(remoteIPMode: .local),
                environment: environment
            )
            let moshArguments = try String(
                contentsOf: directory.appendingPathComponent("mosh.args"),
                encoding: .utf8
            )

            #expect(result.status == 0)
            #expect(moshArguments.firstLine == "--experimental-remote-ip=local")
            #expect(result.stderr.isEmpty)
            let probeOutput = try String(
                contentsOf: directory.appendingPathComponent("ssh.args"),
                encoding: .utf8
            )
            #expect(!probeOutput.contains("SSH_CONNECTION"))
        }
    }

    @Test("activates the SSH management lane before launching Mosh")
    func managementLaneIsReadyBeforeMosh() throws {
        try withFakeCommands(sshStatus: 0, requireManagementReady: true) { directory, environment in
            let result = try run(
                builder(
                    managementReadyShellScript: "printf ready > \"$MANAGEMENT_READY_FILE\""
                ),
                environment: environment
            )
            let moshArguments = try String(
                contentsOf: directory.appendingPathComponent("mosh.args"),
                encoding: .utf8
            )

            #expect(result.status == 0)
            #expect(FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("management.ready").path
            ))
            #expect(!moshArguments.contains("MANAGEMENT_READY_FILE"))
        }
    }

    @Test("creates the attach attempt before staging the remote bootstrap")
    func preparationSeesCurrentAttempt() throws {
        try withFakeCommands(sshStatus: 0) { directory, environment in
            let attemptFile = directory.appendingPathComponent("staged-attempt")
            let result = try run(
                builder(
                    preparationShellScript:
                        "printf '%s' \"$CMUX_SSH_ATTEMPT_ID\" > '\(attemptFile.path)'",
                    remoteRelayPort: 64_007
                ),
                environment: environment
            )
            let stagedAttempt = try String(contentsOf: attemptFile, encoding: .utf8)
            let lifecycleCalls = try String(
                contentsOf: directory.appendingPathComponent("cmux.args"),
                encoding: .utf8
            )

            #expect(result.status == 0)
            #expect(UUID(uuidString: stagedAttempt) != nil)
            #expect(lifecycleCalls.contains(#""attempt_id":"\#(stagedAttempt)""#))
        }
    }

    @Test("runs the staged bootstrap through mosh-server execvp argv semantics")
    func stagedBootstrapSurvivesMoshServerExec() throws {
        try withFakeCommands(
            sshStatus: 0,
            executeRemoteCommand: true,
            installRemoteMoshServerOutsidePath: true,
            moshExecutesRemoteCommand: true
        ) { directory, environment in
            let remoteHome = directory.appendingPathComponent("remote-home", isDirectory: true)
            let staging = try #require(RemoteBootstrapStagingCommandBuilder(
                installerSSHArguments: ["ssh", "-o", "RemoteCommand=none"],
                destination: "user@example.com",
                remoteRelayPort: 52_264,
                bootstrapScript: "printf ran > \"$HOME/bootstrap-ran\""
            ))
            let result = try run(
                builder(
                    preparationShellScript: staging.preparationShellScript,
                    remoteRelayPort: 52_264,
                    remoteCommandArguments: staging.remoteExecutionCommandArguments
                ),
                environment: environment
            )

            #expect(result.status == 0, "stderr: \(result.stderr)")
            #expect(result.stderr.isEmpty)
            #expect(FileManager.default.fileExists(
                atPath: remoteHome.appendingPathComponent("bootstrap-ran").path
            ))
        }
    }

    @Test("does not report connected before the Mosh transport establishes")
    func failedMoshDoesNotReportConnected() throws {
        try withFakeCommands(sshStatus: 0, moshStatus: 71) { directory, environment in
            let result = try run(
                builder(remoteRelayPort: 64_007),
                environment: environment
            )
            let lifecycleCalls = try String(
                contentsOf: directory.appendingPathComponent("cmux.args"),
                encoding: .utf8
            )

            #expect(result.status == 71)
            #expect(lifecycleCalls.contains(
                "rpc workspace.remote.terminal_session_launching"
            ))
            #expect(!lifecycleCalls.contains(
                "rpc workspace.remote.terminal_session_connected"
            ))
        }
    }

    private func builder(
        sshFallbackCommand: String = "exit 90",
        preparationShellScript: String? = nil,
        managementReadyShellScript: String? = nil,
        remoteRelayPort: Int? = nil,
        remoteIPMode: MoshRemoteIPMode = .remote,
        localMoshExecutableName: String = "mosh",
        remoteCommandArguments: [String] = ["command", "space arg", "quote'arg"]
    ) -> MoshTerminalCommandBuilder {
        MoshTerminalCommandBuilder(
            capabilityProbeSSHArguments: ["ssh", "-o", "RemoteCommand=none"],
            sessionSSHArguments: ["ssh", "-o", "RemoteCommand=none", "-p", "2222"],
            localMoshExecutableName: localMoshExecutableName,
            destination: "user@example.com",
            remoteCommandArguments: remoteCommandArguments,
            remoteRelayPort: remoteRelayPort,
            remoteIPMode: remoteIPMode,
            preparationShellScript: preparationShellScript,
            managementReadyShellScript: managementReadyShellScript,
            sshFallbackCommand: sshFallbackCommand,
            localMoshMissingMessage: "local mosh missing",
            localMoshUnsupportedMessage: "local mosh unsupported",
            remoteMoshMissingMessage: "remote mosh missing",
            remoteMoshProbeFailedMessage: "remote probe failed",
            remoteBootstrapInstallFailedMessage: "remote bootstrap install failed",
            remoteMoshAddressFallbackMessage: "mosh address fallback engaged"
        )
    }

    private static var fishExecutablePath: String? {
        [
            "/opt/homebrew/bin/fish",
            "/usr/local/bin/fish",
            "/usr/bin/fish",
        ].first(where: { FileManager.default.isExecutableFile(atPath: $0) })
    }

    private func withFakeCommands(
        sshStatus: Int32,
        installMosh: Bool = true,
        moshSupportsRemoteIP: Bool = true,
        executeRemoteCommand: Bool = false,
        installRemoteMoshServerOutsidePath: Bool = false,
        moshExecutesRemoteCommand: Bool = false,
        requireManagementReady: Bool = false,
        sshConnection: String? = nil,
        sshConnectionStatus: Int32? = nil,
        remoteLoginShell: String = "/bin/sh",
        moshStatus: Int32 = 0,
        operation: (URL, [String: String]) throws -> Void
    ) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-mosh-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        try installExecutable(
            named: "ssh",
            script: """
            #!/bin/sh
            printf '%s\\n' "$@" >> "$SSH_ARGS_FILE"
            printf '%s\\n' '__CMUX_SSH_INVOCATION_END__' >> "$SSH_ARGS_FILE"
            cmux_remote_command=
            for cmux_arg in "$@"; do cmux_remote_command=$cmux_arg; done
            if [ "$FAKE_SSH_EXEC_REMOTE" = "1" ]; then
              SSH_CONNECTION="$FAKE_SSH_CONNECTION" HOME="$FAKE_REMOTE_HOME" PATH=/usr/bin:/bin "$FAKE_REMOTE_LOGIN_SHELL" -c "$cmux_remote_command"
              exit $?
            fi
            case "$cmux_remote_command" in
              *SSH_CONNECTION*)
                if [ -n "${FAKE_SSH_CONNECTION_STATUS:-}" ]; then
                  exit "$FAKE_SSH_CONNECTION_STATUS"
                fi
                printf '%s\\n' "__CMUX_SSH_CONNECTION__${FAKE_SSH_CONNECTION:-}"
                ;;
            esac
            exit "$FAKE_SSH_STATUS"
            """,
            in: directory
        )
        try installExecutable(
            named: "cmux",
            script: """
            #!/bin/sh
            printf '%s\\n' "$*" >> "$CMUX_ARGS_FILE"
            exit 0
            """,
            in: directory
        )
        if installMosh {
            try installExecutable(
                named: "mosh",
                script: """
                #!/bin/sh
                if [ "${1:-}" = "--help" ]; then
                  if [ "$FAKE_MOSH_SUPPORTS_REMOTE_IP" = "1" ]; then
                    printf '%s\\n' '  --experimental-remote-ip=(local|remote|proxy)'
                  fi
                  exit 0
                fi
                if [ "$FAKE_REQUIRE_MANAGEMENT_READY" = "1" ] && [ ! -f "$MANAGEMENT_READY_FILE" ]; then
                  exit 71
                fi
                printf '%s\\n' "$@" > "$MOSH_ARGS_FILE"
                if [ "$FAKE_MOSH_EXECS_REMOTE_COMMAND" = "1" ]; then
                  while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do shift; done
                  if [ "$#" -gt 0 ]; then shift; fi
                  if [ "$#" -gt 0 ]; then shift; fi
                  if [ "$#" -gt 0 ]; then
                    HOME="$FAKE_REMOTE_HOME" exec "$@"
                  fi
                fi
                exit "$FAKE_MOSH_STATUS"
                """,
                in: directory
            )
        }
        let remoteHome = directory.appendingPathComponent("remote-home", isDirectory: true)
        if installRemoteMoshServerOutsidePath {
            let remoteBin = remoteHome.appendingPathComponent(".local/bin", isDirectory: true)
            try FileManager.default.createDirectory(at: remoteBin, withIntermediateDirectories: true)
            try installExecutable(
                named: "mosh-server",
                script: """
                #!/bin/sh
                exit 0
                """,
                in: remoteBin
            )
        }
        try operation(directory, [
            "PATH": directory.path + ":/usr/bin:/bin",
            "FAKE_SSH_STATUS": String(sshStatus),
            "FAKE_SSH_EXEC_REMOTE": executeRemoteCommand ? "1" : "0",
            "FAKE_REMOTE_HOME": remoteHome.path,
            "FAKE_REMOTE_LOGIN_SHELL": remoteLoginShell,
            "FAKE_SSH_CONNECTION": sshConnection ?? "192.0.2.10 12345 192.0.2.20 22",
            "FAKE_SSH_CONNECTION_STATUS": sshConnectionStatus.map(String.init) ?? "",
            "FAKE_MOSH_SUPPORTS_REMOTE_IP": moshSupportsRemoteIP ? "1" : "0",
            "FAKE_MOSH_EXECS_REMOTE_COMMAND": moshExecutesRemoteCommand ? "1" : "0",
            "FAKE_REQUIRE_MANAGEMENT_READY": requireManagementReady ? "1" : "0",
            "FAKE_MOSH_STATUS": String(moshStatus),
            "MANAGEMENT_READY_FILE": directory.appendingPathComponent("management.ready").path,
            "SSH_ARGS_FILE": directory.appendingPathComponent("ssh.args").path,
            "MOSH_ARGS_FILE": directory.appendingPathComponent("mosh.args").path,
            "CMUX_ARGS_FILE": directory.appendingPathComponent("cmux.args").path,
            "CMUX_BUNDLED_CLI_PATH": directory.appendingPathComponent("cmux").path,
            "CMUX_SOCKET_PATH": "/tmp/cmux-mosh-test.sock",
            "CMUX_WORKSPACE_ID": "11111111-1111-1111-1111-111111111111",
            "CMUX_SURFACE_ID": "22222222-2222-2222-2222-222222222222",
            "CMUX_TERMINAL_LIFECYCLE_ID": "33333333-3333-3333-3333-333333333333",
        ])
    }

    private func installExecutable(named name: String, script: String, in directory: URL) throws {
        let url = directory.appendingPathComponent(name)
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func run(
        _ builder: MoshTerminalCommandBuilder,
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

private extension String {
    var firstLine: String {
        split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
    }
}
