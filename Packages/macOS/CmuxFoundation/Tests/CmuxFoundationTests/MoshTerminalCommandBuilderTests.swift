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

    @Test("preserves the Mosh SSH bootstrap and remote command argv")
    func supportedMoshPreservesArguments() throws {
        try withFakeCommands(sshStatus: 0) { directory, environment in
            let result = try run(builder(), environment: environment)
            let moshArguments = String(
                decoding: try Data(contentsOf: directory.appendingPathComponent("mosh.args")),
                as: UTF8.self
            ).split(separator: "\n", omittingEmptySubsequences: false).dropLast().map(String.init)
            let probeArguments = String(
                decoding: try Data(contentsOf: directory.appendingPathComponent("ssh.args")),
                as: UTF8.self
            ).split(separator: "\n", omittingEmptySubsequences: false).dropLast().map(String.init)

            #expect(result.status == 0)
            #expect(result.stdout.isEmpty)
            #expect(result.stderr.isEmpty)
            #expect(Array(probeArguments.prefix(4)) == [
                "-o", "RemoteCommand=none", "-T", "user@example.com",
            ])
            #expect(probeArguments.last?.contains("mosh-server") == true)
            #expect(probeArguments.last?.contains("$HOME/.local/bin") == true)
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
                    preparationShellScript: "false"
                ),
                environment: environment
            )

            #expect(result.status == 0)
            #expect(result.stdout == "ssh fallback\n")
            #expect(result.stderr == "remote probe failed\n")
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

    private func builder(
        sshFallbackCommand: String = "exit 90",
        preparationShellScript: String? = nil,
        managementReadyShellScript: String? = nil,
        localMoshExecutableName: String = "mosh"
    ) -> MoshTerminalCommandBuilder {
        MoshTerminalCommandBuilder(
            capabilityProbeSSHArguments: ["ssh", "-o", "RemoteCommand=none"],
            sessionSSHArguments: ["ssh", "-o", "RemoteCommand=none", "-p", "2222"],
            localMoshExecutableName: localMoshExecutableName,
            destination: "user@example.com",
            remoteCommandArguments: ["command", "space arg", "quote'arg"],
            preparationShellScript: preparationShellScript,
            managementReadyShellScript: managementReadyShellScript,
            sshFallbackCommand: sshFallbackCommand,
            localMoshMissingMessage: "local mosh missing",
            localMoshUnsupportedMessage: "local mosh unsupported",
            remoteMoshMissingMessage: "remote mosh missing",
            remoteMoshProbeFailedMessage: "remote probe failed"
        )
    }

    private func withFakeCommands(
        sshStatus: Int32,
        installMosh: Bool = true,
        moshSupportsRemoteIP: Bool = true,
        executeRemoteCommand: Bool = false,
        installRemoteMoshServerOutsidePath: Bool = false,
        requireManagementReady: Bool = false,
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
            printf '%s\\n' "$@" > "$SSH_ARGS_FILE"
            if [ "$FAKE_SSH_EXEC_REMOTE" = "1" ]; then
              cmux_remote_command=
              for cmux_arg in "$@"; do cmux_remote_command=$cmux_arg; done
              HOME="$FAKE_REMOTE_HOME" PATH=/usr/bin:/bin /bin/sh -c "$cmux_remote_command"
              exit $?
            fi
            exit "$FAKE_SSH_STATUS"
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
            "PATH": directory.path,
            "FAKE_SSH_STATUS": String(sshStatus),
            "FAKE_SSH_EXEC_REMOTE": executeRemoteCommand ? "1" : "0",
            "FAKE_REMOTE_HOME": remoteHome.path,
            "FAKE_MOSH_SUPPORTS_REMOTE_IP": moshSupportsRemoteIP ? "1" : "0",
            "FAKE_REQUIRE_MANAGEMENT_READY": requireManagementReady ? "1" : "0",
            "MANAGEMENT_READY_FILE": directory.appendingPathComponent("management.ready").path,
            "SSH_ARGS_FILE": directory.appendingPathComponent("ssh.args").path,
            "MOSH_ARGS_FILE": directory.appendingPathComponent("mosh.args").path,
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
