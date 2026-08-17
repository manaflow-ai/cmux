import Foundation
import Testing
@testable import CmuxFoundation

@Suite("Remote bootstrap staging")
struct RemoteBootstrapStagingCommandBuilderTests {
    @Test("streams a large substituted bootstrap without placing it in SSH argv")
    func stagesLargeBootstrapOverStandardInput() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-bootstrap-stage-\(UUID().uuidString)", isDirectory: true)
        let remoteHome = directory.appendingPathComponent("remote-home", isDirectory: true)
        try FileManager.default.createDirectory(at: remoteHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let fakeSSH = directory.appendingPathComponent("ssh")
        try """
        #!/bin/sh
        printf '%s\\n' "$@" > "$CMUX_SSH_ARGUMENTS"
        cmux_remote_command=
        for cmux_argument in "$@"; do cmux_remote_command=$cmux_argument; done
        HOME="$CMUX_REMOTE_HOME" /bin/sh -c "$cmux_remote_command"
        """.write(to: fakeSSH, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: fakeSSH.path
        )

        let padding = String(repeating: "# bootstrap padding 0123456789\n", count: 20_000)
        let bootstrap = """
        printf '%s\\n' 'workspace=__CMUX_WORKSPACE_ID__ surface=__CMUX_SURFACE_ID__ lifecycle=__CMUX_TERMINAL_LIFECYCLE_ID__ attempt=__CMUX_SSH_ATTEMPT_ID__'
        \(padding)
        """
        let builder = try #require(RemoteBootstrapStagingCommandBuilder(
            installerSSHArguments: [fakeSSH.path, "-o", "RemoteCommand=none"],
            destination: "user@example.com",
            remoteRelayPort: 52_261,
            bootstrapScript: bootstrap
        ))
        let environment = [
            "PATH": "/usr/bin:/bin",
            "CMUX_WORKSPACE_ID": "workspace-123",
            "CMUX_SURFACE_ID": "surface-456",
            "CMUX_TERMINAL_LIFECYCLE_ID": "lifecycle-789",
            "CMUX_SSH_ATTEMPT_ID": "attempt-012",
            "CMUX_REMOTE_HOME": remoteHome.path,
            "CMUX_SSH_ARGUMENTS": directory.appendingPathComponent("ssh.args").path,
        ]

        let preparation = try run(
            executable: "/bin/sh",
            arguments: ["-c", builder.preparationShellScript],
            environment: environment
        )
        #expect(preparation.status == 0)
        #expect(preparation.stderr.isEmpty)

        let stagedURL = remoteHome.appendingPathComponent(".cmux/relay/52261.bootstrap.sh")
        let staged = String(decoding: try Data(contentsOf: stagedURL), as: UTF8.self)
        #expect(staged.contains(
            "workspace=workspace-123 surface=surface-456 lifecycle=lifecycle-789 attempt=attempt-012"
        ))
        #expect(!staged.contains("__CMUX_WORKSPACE_ID__"))
        #expect(!staged.contains("__CMUX_SURFACE_ID__"))
        #expect(!staged.contains("__CMUX_TERMINAL_LIFECYCLE_ID__"))
        #expect(!staged.contains("__CMUX_SSH_ATTEMPT_ID__"))
        #expect(staged.utf8.count > 500_000)

        let sshArguments = String(
            decoding: try Data(contentsOf: directory.appendingPathComponent("ssh.args")),
            as: UTF8.self
        )
        .split(separator: "\n")
        .map(String.init)
        #expect(sshArguments.allSatisfy { $0.utf8.count < 4_096 })
        #expect(sshArguments.contains(where: { $0.hasPrefix("/bin/sh -c '") }))

        let execution = try run(
            executable: "/bin/sh",
            arguments: ["-c", builder.remoteExecutionShellScript],
            environment: [
                "HOME": remoteHome.path,
                "PATH": "/usr/bin:/bin",
            ]
        )
        #expect(execution.status == 0)
        #expect(
            execution.stdout ==
                "workspace=workspace-123 surface=surface-456 lifecycle=lifecycle-789 attempt=attempt-012\n"
        )
        #expect(execution.stderr.isEmpty)
    }

    @Test("execution argv runs the staged bootstrap under execvp semantics")
    func executionArgumentsSurviveExecvp() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-bootstrap-argv-\(UUID().uuidString)", isDirectory: true)
        let remoteHome = directory.appendingPathComponent("remote-home", isDirectory: true)
        let relayDirectory = remoteHome.appendingPathComponent(".cmux/relay", isDirectory: true)
        try FileManager.default.createDirectory(at: relayDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        try "printf '%s\\n' argv-bootstrap\n".write(
            to: relayDirectory.appendingPathComponent("52264.bootstrap.sh"),
            atomically: true,
            encoding: .utf8
        )
        let builder = try #require(RemoteBootstrapStagingCommandBuilder(
            installerSSHArguments: ["ssh"],
            destination: "user@example.com",
            remoteRelayPort: 52_264,
            bootstrapScript: "printf '%s\\n' argv-bootstrap"
        ))

        // mosh-server executes the received command argv with execvp and no
        // shell parsing, so the first element must be a real executable path.
        let arguments = builder.remoteExecutionCommandArguments
        let execution = try run(
            executable: try #require(arguments.first),
            arguments: Array(arguments.dropFirst()),
            environment: [
                "HOME": remoteHome.path,
                "PATH": "/usr/bin:/bin",
            ]
        )
        #expect(execution.status == 0)
        #expect(execution.stdout == "argv-bootstrap\n")
        #expect(execution.stderr.isEmpty)
    }

    @Test(
        "installs through POSIX sh when the remote login shell is fish",
        .enabled(if: RemoteBootstrapStagingCommandBuilderTests.fishExecutablePath != nil)
    )
    func stagesThroughFishLoginShell() throws {
        let fishPath = try #require(Self.fishExecutablePath)

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-bootstrap-fish-\(UUID().uuidString)", isDirectory: true)
        let remoteHome = directory.appendingPathComponent("remote-home", isDirectory: true)
        try FileManager.default.createDirectory(at: remoteHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let fakeSSH = directory.appendingPathComponent("ssh")
        try """
        #!/bin/sh
        cmux_remote_command=
        for cmux_argument in "$@"; do cmux_remote_command=$cmux_argument; done
        HOME="$CMUX_REMOTE_HOME" PATH=/usr/bin:/bin "$CMUX_FISH_PATH" -c "$cmux_remote_command"
        """.write(to: fakeSSH, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: fakeSSH.path
        )

        let builder = try #require(RemoteBootstrapStagingCommandBuilder(
            installerSSHArguments: [fakeSSH.path, "-o", "RemoteCommand=none"],
            destination: "user@example.com",
            remoteRelayPort: 52_262,
            bootstrapScript: "printf '%s\\n' fish-bootstrap"
        ))
        let preparation = try run(
            executable: "/bin/sh",
            arguments: ["-c", builder.preparationShellScript],
            environment: [
                "PATH": "/usr/bin:/bin",
                "CMUX_REMOTE_HOME": remoteHome.path,
                "CMUX_FISH_PATH": fishPath,
            ]
        )

        #expect(preparation.status == 0)
        #expect(preparation.stderr.isEmpty)
        #expect(FileManager.default.fileExists(
            atPath: remoteHome.appendingPathComponent(".cmux/relay/52262.bootstrap.sh").path
        ))

        let execution = try run(
            executable: fishPath,
            arguments: ["-c", builder.remoteExecutionShellScript],
            environment: [
                "HOME": remoteHome.path,
                "PATH": "/usr/bin:/bin",
            ]
        )
        #expect(execution.status == 0)
        #expect(execution.stdout == "fish-bootstrap\n")
        #expect(execution.stderr.isEmpty)
    }

    @Test("returns installer status and captured stderr")
    func reportsInstallerFailure() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-bootstrap-failure-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let fakeSSH = directory.appendingPathComponent("ssh")
        try """
        #!/bin/sh
        cat >/dev/null
        printf '%s\\n' 'remote installer stderr' >&2
        exit 23
        """.write(to: fakeSSH, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: fakeSSH.path
        )

        let builder = try #require(RemoteBootstrapStagingCommandBuilder(
            installerSSHArguments: [fakeSSH.path, "-o", "RemoteCommand=none"],
            destination: "user@example.com",
            remoteRelayPort: 52_263,
            bootstrapScript: "true"
        ))
        let preparation = try run(
            executable: "/bin/sh",
            arguments: ["-c", builder.preparationShellScript],
            environment: [
                "PATH": "/usr/bin:/bin",
            ]
        )

        #expect(preparation.status == 23)
        #expect(preparation.stderr.contains("remote installer stderr"))
        #expect(!FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("remote-home/.cmux/relay/52263.bootstrap.sh").path
        ))
    }

    @Test("rejects an invalid relay namespace")
    func invalidRelayPort() {
        #expect(RemoteBootstrapStagingCommandBuilder(
            installerSSHArguments: ["ssh"],
            destination: "host",
            remoteRelayPort: 0,
            bootstrapScript: "true"
        ) == nil)
    }

    private func run(
        executable: String,
        arguments: [String],
        environment: [String: String]
    ) throws -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
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

    private static var fishExecutablePath: String? {
        [
            "/opt/homebrew/bin/fish",
            "/usr/local/bin/fish",
            "/usr/bin/fish",
        ].first(where: { FileManager.default.isExecutableFile(atPath: $0) })
    }
}
