import Foundation
import Testing
@testable import CmuxFoundation

@Suite("Remote tmux executable resolution")
struct RemoteTmuxCommandBuilderTests {
    @Test("remote argv resolves tmux and preserves every argument")
    func remoteCommandArgumentsExecute() throws {
        try withFakeTmux { directory, environment in
            let builder = RemoteTmuxCommandBuilder(arguments: [
                "new-session", "-A", "-s", "agent main", "quote'arg",
            ])
            let result = try run(
                executable: builder.remoteCommandArguments[0],
                arguments: Array(builder.remoteCommandArguments.dropFirst()),
                environment: environment
            )

            #expect(result.status == 0)
            #expect(result.stderr.isEmpty)
            #expect(try capturedArguments(in: directory) == [
                "new-session", "-A", "-s", "agent main", "quote'arg",
            ])
        }
    }

    @Test("shell command preserves arguments through the outer login shell")
    func remoteShellCommandExecutes() throws {
        try withFakeTmux { directory, environment in
            let builder = RemoteTmuxCommandBuilder(arguments: [
                "new-session", "-A", "-s", "space and ' quote",
            ])
            let result = try run(
                executable: "/bin/sh",
                arguments: ["-c", builder.remoteShellCommand],
                environment: environment
            )

            #expect(result.status == 0)
            #expect(result.stderr.isEmpty)
            #expect(try capturedArguments(in: directory) == [
                "new-session", "-A", "-s", "space and ' quote",
            ])
        }
    }

    private func withFakeTmux(
        operation: (URL, [String: String]) throws -> Void
    ) throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "cmux-remote-tmux-builder-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let executable = directory.appending(path: "tmux")
        try """
        #!/bin/sh
        printf '%s\\n' "$@" > "$TMUX_ARGS_FILE"
        """.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )
        try operation(directory, [
            "HOME": directory.path,
            "PATH": directory.path,
            "TMUX_ARGS_FILE": directory.appending(path: "tmux.args").path,
        ])
    }

    private func capturedArguments(in directory: URL) throws -> [String] {
        String(
            decoding: try Data(contentsOf: directory.appending(path: "tmux.args")),
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
    ) throws -> (status: Int32, stderr: String) {
        let process = Process()
        let standardError = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.standardError = standardError
        try process.run()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            String(decoding: standardError.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        )
    }
}
