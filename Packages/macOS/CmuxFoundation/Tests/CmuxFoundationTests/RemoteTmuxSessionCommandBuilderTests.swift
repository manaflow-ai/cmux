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
                [
                    "new-session", "-d",
                    "-e", "CMUX_BUNDLED_CLI_PATH=",
                    "-e", "CMUX_SHELL_INTEGRATION=",
                    "-e", "CMUX_SHELL_INTEGRATION_DIR=",
                    "-e", "CMUX_SOCKET_PATH=",
                    "-e", "CMUX_TAB_ID=",
                    "-e", "CMUX_WORKSPACE_ID=",
                    "-e", "CMUX_INITIAL_COMMAND_FILE=",
                    "-e", "CMUX_PANEL_ID=",
                    "-e", "CMUX_SURFACE_ID=",
                    "-s", "agent main", shellCommand,
                ],
                ["set-environment", "-t", "=agent main", "-u", "CMUX_BUNDLED_CLI_PATH"],
                ["set-environment", "-t", "=agent main", "-u", "CMUX_SHELL_INTEGRATION"],
                ["set-environment", "-t", "=agent main", "-u", "CMUX_SHELL_INTEGRATION_DIR"],
                ["set-environment", "-t", "=agent main", "-u", "CMUX_SOCKET_PATH"],
                ["set-environment", "-t", "=agent main", "-u", "CMUX_TAB_ID"],
                ["set-environment", "-t", "=agent main", "-u", "CMUX_WORKSPACE_ID"],
                ["set-environment", "-t", "=agent main", "-u", "CMUX_INITIAL_COMMAND_FILE"],
                ["set-environment", "-t", "=agent main", "-u", "CMUX_PANEL_ID"],
                ["set-environment", "-t", "=agent main", "-u", "CMUX_SURFACE_ID"],
                ["set-option", "-t", "=agent main:", "default-command", shellCommand],
                ["attach-session", "-t", "=agent main"],
            ])
        }
    }

    @Test("new session binds current workspace metadata before its first shell starts")
    func newSessionBindsWorkspaceMetadataBeforeFirstShell() throws {
        try withFakeTmux(sessionExists: false) { directory, environment in
            let shellCommand = "exec integrated-shell"
            let builder = RemoteTmuxSessionCommandBuilder(
                sessionName: "fresh",
                shellCommand: shellCommand
            )
            let currentWorkspace = "11111111-1111-1111-1111-111111111111"
            let currentSurface = "22222222-2222-2222-2222-222222222222"
            let currentSocket = "127.0.0.1:55272"
            let currentEnvironment = [
                "CMUX_BUNDLED_CLI_PATH": "/home/dev/.cmux/bin/cmux",
                "CMUX_PANEL_ID": currentSurface,
                "CMUX_SHELL_INTEGRATION": "1",
                "CMUX_SHELL_INTEGRATION_DIR": "/home/dev/.cmux/relay/55272.shell",
                "CMUX_SOCKET_PATH": currentSocket,
                "CMUX_SURFACE_ID": currentSurface,
                "CMUX_TAB_ID": currentWorkspace,
                "CMUX_WORKSPACE_ID": currentWorkspace,
            ]
            let result = try run(
                builder.remoteShellCommand,
                environment: environment.merging(currentEnvironment) { _, current in current }
            )

            #expect(result.status == 0)
            #expect(result.stderr.isEmpty)
            let calls = try invocations(in: directory)
            let newSessionCall = try #require(calls.first { $0.first == "new-session" })
            #expect(newSessionCall == [
                "new-session", "-d",
                "-e", "CMUX_BUNDLED_CLI_PATH=/home/dev/.cmux/bin/cmux",
                "-e", "CMUX_SHELL_INTEGRATION=1",
                "-e", "CMUX_SHELL_INTEGRATION_DIR=/home/dev/.cmux/relay/55272.shell",
                "-e", "CMUX_SOCKET_PATH=\(currentSocket)",
                "-e", "CMUX_TAB_ID=\(currentWorkspace)",
                "-e", "CMUX_WORKSPACE_ID=\(currentWorkspace)",
                "-e", "CMUX_INITIAL_COMMAND_FILE=",
                "-e", "CMUX_PANEL_ID=",
                "-e", "CMUX_SURFACE_ID=",
                "-s", "fresh", shellCommand,
            ])

            let newSessionIndex = try #require(calls.firstIndex(of: newSessionCall))
            let setOptionIndex = try #require(calls.firstIndex {
                $0.first == "set-option"
            })
            for (key, value) in currentEnvironment where key != "CMUX_PANEL_ID" && key != "CMUX_SURFACE_ID" {
                let expectedCall = ["set-environment", "-t", "=fresh", key, value]
                let index = try #require(calls.firstIndex(of: expectedCall), "missing tmux call: \(expectedCall)")
                #expect(newSessionIndex < index)
                #expect(index < setOptionIndex)
            }
        }
    }

    @Test("new session passes the one-shot command payload only to its first shell")
    func newSessionPassesInitialCommandPayloadToFirstShell() throws {
        try withFakeTmux(sessionExists: false) { directory, environment in
            let initialCommandFile = "/home/dev/.cmux/relay/55272.shell/initial-command.payload"
            let builder = RemoteTmuxSessionCommandBuilder(
                sessionName: "fresh-command",
                shellCommand: "exec integrated-shell"
            )
            let result = try run(
                builder.remoteShellCommand,
                environment: environment.merging([
                    "CMUX_INITIAL_COMMAND_FILE": initialCommandFile,
                ]) { _, current in current }
            )

            #expect(result.status == 0)
            #expect(result.stderr.isEmpty)
            let calls = try invocations(in: directory)
            let newSessionCall = try #require(calls.first { $0.first == "new-session" })
            #expect(newSessionCall.contains("CMUX_INITIAL_COMMAND_FILE=\(initialCommandFile)"))

            let newSessionIndex = try #require(calls.firstIndex(of: newSessionCall))
            let clearCall = [
                "set-environment", "-t", "=fresh-command", "-u", "CMUX_INITIAL_COMMAND_FILE",
            ]
            let clearIndex = try #require(calls.firstIndex(of: clearCall))
            let setOptionIndex = try #require(calls.firstIndex { $0.first == "set-option" })
            #expect(newSessionIndex < clearIndex)
            #expect(clearIndex < setOptionIndex)
        }
    }

    @Test("existing session rebinds workspace metadata before attach without mutating user options")
    func existingSessionRebindsWorkspaceMetadata() throws {
        try withFakeTmux(sessionExists: true) { directory, environment in
            let builder = RemoteTmuxSessionCommandBuilder(
                sessionName: "existing",
                shellCommand: "exec integrated-shell"
            )
            let currentWorkspace = "11111111-1111-1111-1111-111111111111"
            let currentSocket = "127.0.0.1:55272"
            let result = try run(builder.remoteShellCommand, environment: environment.merging([
                "CMUX_BUNDLED_CLI_PATH": "/home/dev/.cmux/bin/cmux",
                "CMUX_PANEL_ID": "22222222-2222-2222-2222-222222222222",
                "CMUX_SHELL_INTEGRATION_DIR": "/home/dev/.cmux/relay/55272.shell",
                "CMUX_SOCKET_PATH": currentSocket,
                "CMUX_SURFACE_ID": "22222222-2222-2222-2222-222222222222",
                "CMUX_TAB_ID": currentWorkspace,
                "CMUX_WORKSPACE_ID": currentWorkspace,
            ]) { _, current in current })

            #expect(result.status == 0)
            #expect(result.stderr.isEmpty)
            let calls = try invocations(in: directory)
            let attachIndex = try #require(calls.firstIndex(of: ["attach-session", "-t", "=existing"]))
            let expectedBeforeAttach = [
                ["set-environment", "-t", "=existing", "CMUX_BUNDLED_CLI_PATH", "/home/dev/.cmux/bin/cmux"],
                ["set-environment", "-t", "=existing", "CMUX_SHELL_INTEGRATION_DIR", "/home/dev/.cmux/relay/55272.shell"],
                ["set-environment", "-t", "=existing", "CMUX_SOCKET_PATH", currentSocket],
                ["set-environment", "-t", "=existing", "CMUX_TAB_ID", currentWorkspace],
                ["set-environment", "-t", "=existing", "CMUX_WORKSPACE_ID", currentWorkspace],
                ["set-environment", "-t", "=existing", "-u", "CMUX_PANEL_ID"],
                ["set-environment", "-t", "=existing", "-u", "CMUX_SURFACE_ID"],
            ]
            for expectedCall in expectedBeforeAttach {
                let index = try #require(calls.firstIndex(of: expectedCall), "missing tmux call: \(expectedCall)")
                #expect(index < attachIndex)
            }
            #expect(!calls.contains { $0.first == "set-option" })
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
