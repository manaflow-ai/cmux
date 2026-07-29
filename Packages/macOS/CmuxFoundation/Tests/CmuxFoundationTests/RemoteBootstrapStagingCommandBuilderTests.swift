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
        printf '%s\\n' 'workspace=__CMUX_WORKSPACE_ID__ surface=__CMUX_SURFACE_ID__'
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
        #expect(staged.contains("workspace=workspace-123 surface=surface-456"))
        #expect(!staged.contains("__CMUX_WORKSPACE_ID__"))
        #expect(!staged.contains("__CMUX_SURFACE_ID__"))
        #expect(staged.utf8.count > 500_000)

        let sshArguments = String(
            decoding: try Data(contentsOf: directory.appendingPathComponent("ssh.args")),
            as: UTF8.self
        )
        .split(separator: "\n")
        .map(String.init)
        #expect(sshArguments.allSatisfy { $0.utf8.count < 4_096 })

        let execution = try run(
            executable: "/bin/sh",
            arguments: ["-c", builder.remoteExecutionShellScript],
            environment: [
                "HOME": remoteHome.path,
                "PATH": "/usr/bin:/bin",
            ]
        )
        #expect(execution.status == 0)
        #expect(execution.stdout == "workspace=workspace-123 surface=surface-456\n")
        #expect(execution.stderr.isEmpty)
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
}
