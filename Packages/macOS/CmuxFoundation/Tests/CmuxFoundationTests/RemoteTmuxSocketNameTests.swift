import Foundation
import Testing
@testable import CmuxFoundation

/// `tmux -L <name>` selection for remote mirrors (#15022). The name is interpolated into a
/// remote shell command, so the accepted character set is strict and the argument builder
/// is what puts `-L` in front of every tmux argument vector.
@Suite("Remote tmux socket name")
struct RemoteTmuxSocketNameTests {
    static let longestAllowed = String(repeating: "a", count: 64)
    static let oneTooLong = String(repeating: "a", count: 65)

    static let accepted: [String] = ["alpha", "proj.v2", "team_a", "a-b-c", "A1", "x", longestAllowed]
    static let rejected: [String] = [
        "", " ", "a b", "a/b", "a;b", "a'b", "a\"b", "a$b", "a`b", "a\nb", "名前", "é", oneTooLong,
    ]

    @Test(arguments: accepted)
    func acceptsLettersDigitsDotUnderscoreAndHyphen(_ name: String) {
        #expect(RemoteTmuxSocketName.isValid(name))
    }

    @Test(arguments: rejected)
    func rejectsEverythingElse(_ name: String) {
        #expect(!RemoteTmuxSocketName.isValid(name))
    }

    @Test func argumentsAreEmptyWithoutAName() {
        #expect(RemoteTmuxSocketName.arguments(for: nil) == [])
        #expect(RemoteTmuxSocketName.arguments(for: "alpha") == ["-L", "alpha"])
    }

    @Test("builder puts -L <name> before the tmux arguments")
    func builderPrependsSocketFlag() throws {
        try withFakeTmux { directory, environment in
            let builder = RemoteTmuxCommandBuilder(
                arguments: ["-CC", "attach-session", "-t", "work"],
                socketName: "alpha"
            )
            let result = try run(
                executable: builder.remoteCommandArguments[0],
                arguments: Array(builder.remoteCommandArguments.dropFirst()),
                environment: environment
            )
            #expect(result.status == 0)
            #expect(result.stderr.isEmpty)
            #expect(try capturedArguments(in: directory) == [
                "-L", "alpha", "-CC", "attach-session", "-t", "work",
            ])
        }
    }

    @Test("shell command delivers the socket name intact through the outer shell")
    func shellCommandQuotesSocketName() throws {
        try withFakeTmux { directory, environment in
            // The CLI never lets a name like this through; the builder still has to quote it
            // because it is a general-purpose seam shared with other remote callers.
            let builder = RemoteTmuxCommandBuilder(
                arguments: ["list-sessions"],
                socketName: "space and ' quote"
            )
            let result = try run(
                executable: "/bin/sh",
                arguments: ["-c", builder.remoteShellCommand],
                environment: environment
            )
            #expect(result.status == 0)
            #expect(result.stderr.isEmpty)
            #expect(try capturedArguments(in: directory) == [
                "-L", "space and ' quote", "list-sessions",
            ])
        }
    }

    @Test("no socket name leaves the argument vector unchanged")
    func noSocketNameIsTheDefault() throws {
        try withFakeTmux { directory, environment in
            let builder = RemoteTmuxCommandBuilder(arguments: ["list-sessions"])
            let result = try run(
                executable: "/bin/sh",
                arguments: ["-c", builder.remoteShellCommand],
                environment: environment
            )
            #expect(result.status == 0)
            #expect(try capturedArguments(in: directory) == ["list-sessions"])
        }
    }

    private func withFakeTmux(
        operation: (URL, [String: String]) throws -> Void
    ) throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "cmux-remote-tmux-socket-\(UUID().uuidString)", directoryHint: .isDirectory)
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
