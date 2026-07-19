import Foundation
import Testing
@testable import CmuxFoundation

@Suite("Mosh terminal command selection and fallback")
struct MoshTerminalCommandBuilderTests {
    @Test("falls back to SSH when Mosh is missing locally")
    func localMoshMissingFallsBack() throws {
        try withFakeCommands(sshStatus: 0, installMosh: false) { directory, environment in
            let result = try run(
                builder(sshFallbackCommand: "printf 'ssh fallback\\n'"),
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
            #expect(probeArguments == [
                "-o", "RemoteCommand=none", "-T", "user@example.com",
                "command -v mosh-server >/dev/null 2>&1 || exit 127",
            ])
            #expect(moshArguments == [
                "--experimental-remote-ip=remote",
                "--ssh='ssh' '-o' 'RemoteCommand=none' '-p' '2222'",
                "--",
                "user@example.com",
                "command",
                "space arg",
                "quote'arg",
            ])
        }
    }

    private func builder(sshFallbackCommand: String = "exit 90") -> MoshTerminalCommandBuilder {
        MoshTerminalCommandBuilder(
            capabilityProbeSSHArguments: ["ssh", "-o", "RemoteCommand=none"],
            sessionSSHArguments: ["ssh", "-o", "RemoteCommand=none", "-p", "2222"],
            destination: "user@example.com",
            remoteCommandArguments: ["command", "space arg", "quote'arg"],
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
                printf '%s\\n' "$@" > "$MOSH_ARGS_FILE"
                """,
                in: directory
            )
        }
        try operation(directory, [
            "PATH": directory.path,
            "FAKE_SSH_STATUS": String(sshStatus),
            "FAKE_MOSH_SUPPORTS_REMOTE_IP": moshSupportsRemoteIP ? "1" : "0",
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
