import Foundation
import Testing
@testable import CmuxFoundation

@Suite("Remote executable resolution")
struct RemoteExecutableCommandBuilderTests {
    @Test("resolves and executes a user-local binary outside PATH")
    func userLocalBinaryOutsidePath() throws {
        try withFakeExecutable { directory, environment in
            let builder = RemoteExecutableCommandBuilder(
                executableName: "cmux-fake-tool",
                notFoundSentinel: "fake tool missing"
            )
            let result = try run(
                executable: builder.remoteCommandArguments(arguments: [
                    "space arg", "quote'arg",
                ])[0],
                arguments: Array(builder.remoteCommandArguments(arguments: [
                    "space arg", "quote'arg",
                ]).dropFirst()),
                environment: environment
            )

            #expect(result.status == 0)
            #expect(result.stderr.isEmpty)
            #expect(try capturedArguments(in: directory) == [
                "space arg", "quote'arg",
            ])
        }
    }

    @Test("probe prints the resolved user-local path")
    func resolutionProbe() throws {
        try withFakeExecutable { directory, environment in
            let builder = RemoteExecutableCommandBuilder(
                executableName: "cmux-fake-tool",
                notFoundSentinel: "fake tool missing"
            )
            let result = try run(
                executable: "/bin/sh",
                arguments: ["-c", builder.resolutionProbeShellCommand],
                environment: environment
            )

            #expect(result.status == 0)
            #expect(result.stdout == directory.appendingPathComponent(".local/bin/cmux-fake-tool").path + "\n")
            #expect(result.stderr.isEmpty)
        }
    }

    @Test("exec prefix accepts arguments appended by a remote launcher")
    func execPrefixAcceptsAppendedArguments() throws {
        try withFakeExecutable { directory, environment in
            let builder = RemoteExecutableCommandBuilder(
                executableName: "cmux-fake-tool",
                notFoundSentinel: "fake tool missing"
            )
            let command = builder.remoteExecPrefixShellCommand + " 'new' 'space arg'"
            let result = try run(
                executable: "/bin/sh",
                arguments: ["-c", command],
                environment: environment
            )

            #expect(result.status == 0)
            #expect(result.stderr.isEmpty)
            #expect(try capturedArguments(in: directory) == ["new", "space arg"])
        }
    }

    @Test("missing executable emits the sentinel and exits 127")
    func missingExecutable() throws {
        let builder = RemoteExecutableCommandBuilder(
            executableName: "cmux-definitely-missing-tool",
            notFoundSentinel: "fake tool missing"
        )
        let result = try run(
            executable: "/bin/sh",
            arguments: ["-c", builder.resolutionProbeShellCommand],
            environment: [
                "HOME": "/nonexistent/cmux-test-home",
                "PATH": "/usr/bin:/bin",
            ]
        )

        #expect(result.status == 127)
        #expect(result.stdout.isEmpty)
        #expect(result.stderr == "fake tool missing\n")
    }

    private func withFakeExecutable(
        operation: (URL, [String: String]) throws -> Void
    ) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-remote-executable-\(UUID().uuidString)", isDirectory: true)
        let executableDirectory = directory.appendingPathComponent(".local/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: executableDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let executable = executableDirectory.appendingPathComponent("cmux-fake-tool")
        try """
        #!/bin/sh
        printf '%s\\n' "$@" > "$CMUX_CAPTURED_ARGUMENTS"
        """.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )
        try operation(directory, [
            "HOME": directory.path,
            "PATH": "/usr/bin:/bin",
            "CMUX_CAPTURED_ARGUMENTS": directory.appendingPathComponent("arguments").path,
        ])
    }

    private func capturedArguments(in directory: URL) throws -> [String] {
        String(
            decoding: try Data(contentsOf: directory.appendingPathComponent("arguments")),
            as: UTF8.self
        )
        .split(separator: "\n", omittingEmptySubsequences: false)
        .dropLast()
        .map(String.init)
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
