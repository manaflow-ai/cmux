import Foundation
import Testing
@testable import CmuxFoundation

@Suite("Remote tmux session launch behavior")
struct RemoteTmuxSessionCommandBuilderTests {
    @Test("new session installs the integrated shell command for current and future panes")
    func createsIntegratedSession() throws {
        try withFakeTmux(sessionExists: false) { directory, environment in
            let shellCommand = #"exec "${SHELL:-/bin/bash}" --rcfile "$HOME/cmux rc" -i"#
            let builder = RemoteTmuxSessionCommandBuilder(
                sessionName: "agent main",
                shellCommand: shellCommand
            )
            let result = try run(builder.remoteShellCommand, environment: environment)

            #expect(result.status == 0)
            #expect(result.stderr.isEmpty)
            #expect(try invocations(in: directory) == [
                ["has-session", "-t", "=agent main"],
                ["new-session", "-d", "-s", "agent main", shellCommand],
                ["set-option", "-t", "=agent main", "default-command", shellCommand],
                ["attach-session", "-t", "=agent main"],
            ])
        }
    }

    @Test("existing session attaches without mutating user options")
    func existingSessionIsNotMutated() throws {
        try withFakeTmux(sessionExists: true) { directory, environment in
            let builder = RemoteTmuxSessionCommandBuilder(
                sessionName: "existing",
                shellCommand: "exec integrated-shell"
            )
            let result = try run(builder.remoteShellCommand, environment: environment)

            #expect(result.status == 0)
            #expect(result.stderr.isEmpty)
            #expect(try invocations(in: directory) == [
                ["has-session", "-t", "=existing"],
                ["attach-session", "-t", "=existing"],
            ])
        }
    }

    private func withFakeTmux(
        sessionExists: Bool,
        operation: (URL, [String: String]) throws -> Void
    ) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-tmux-session-\(UUID().uuidString)", isDirectory: true)
        let executableDirectory = directory.appendingPathComponent(".local/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: executableDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let executable = executableDirectory.appendingPathComponent("tmux")
        try """
        #!/bin/sh
        printf '%s\\034' "$@" >> "$CMUX_TMUX_LOG"
        printf '\\n' >> "$CMUX_TMUX_LOG"
        case "${1:-}" in
          has-session)
            [ -f "$CMUX_TMUX_SESSION_STATE" ]
            ;;
          new-session)
            : > "$CMUX_TMUX_SESSION_STATE"
            ;;
        esac
        """.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )
        let statePath = directory.appendingPathComponent("session-state").path
        if sessionExists {
            try Data().write(to: URL(fileURLWithPath: statePath))
        }
        try operation(directory, [
            "HOME": directory.path,
            "PATH": "/usr/bin:/bin",
            "CMUX_TMUX_LOG": directory.appendingPathComponent("tmux.log").path,
            "CMUX_TMUX_SESSION_STATE": statePath,
        ])
    }

    private func invocations(in directory: URL) throws -> [[String]] {
        String(
            decoding: try Data(contentsOf: directory.appendingPathComponent("tmux.log")),
            as: UTF8.self
        )
        .split(separator: "\n")
        .map { line in
            line.split(separator: "\u{1c}", omittingEmptySubsequences: true).map(String.init)
        }
    }

    private func run(
        _ command: String,
        environment: [String: String]
    ) throws -> (status: Int32, stderr: String) {
        let process = Process()
        let standardError = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
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
