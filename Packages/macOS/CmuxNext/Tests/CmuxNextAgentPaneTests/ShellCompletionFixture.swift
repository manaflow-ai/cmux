import Foundation
import Testing

@testable import CmuxNextAgentPane

/// A disposable shell home and working directory; no completion test inherits host settings.
struct ShellCompletionFixture {
    let directory: URL
    let shell: String

    init(shell: String, files: [String] = [], directories: [String] = []) throws {
        self.shell = shell
        directory = FileManager.default.temporaryDirectory
            .appending(path: "complete-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            for name in directories {
                try FileManager.default.createDirectory(at: directory.appending(path: name), withIntermediateDirectories: true)
            }
            for name in files + [".bashrc", ".bash_profile", ".profile", ".zshrc", ".zprofile", ".zshenv"] {
                try Data().write(to: directory.appending(path: name))
            }
            // Exercise the production scripts and process continuation with real shells, but
            // replace their login startup with test-owned rc files and completion cache.
            let invocation: String
            switch shell {
            case "bash": invocation = #"exec /bin/bash --noprofile --norc --rcfile "$HOME/.bashrc" "$@""#
            case "zsh": invocation = #"exec /bin/zsh -d "$@""#
            default: preconditionFailure("Unsupported completion test shell: \(shell)")
            }
            let script = """
            #!/bin/sh
            if [ "$1" = "-l" ]; then shift; fi
            export CMUX_COMPLETE_DUMP="$HOME/.zcompdump"
            \(invocation)

            """
            let executable = directory.appending(path: shell)
            try Data(script.utf8).write(to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        } catch {
            remove()
            throw error
        }
    }

    var cwd: String { directory.path }

    var environment: [String: String] {
        ["HOME": cwd, "ZDOTDIR": cwd, "HISTFILE": "\(cwd)/history", "BASH_ENV": "\(cwd)/.bashrc",
         "CMUX_COMPLETE_DUMP": "\(cwd)/.zcompdump",
         "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C", "TERM": "xterm"]
    }

    var completion: AgentPaneShellCompletion {
        AgentPaneShellCompletion(
            shell: directory.appending(path: shell).path,
            environment: environment,
            home: cwd,
            timeout: .seconds(60)
        )
    }

    /// Await the actual reply (stdout EOF and shell exit resume CompletionProcess's continuation).
    /// The 60-second deadline can only fail the test; it never supplies a successful result.
    func complete(_ line: String) async throws -> AgentPaneShellCompletion.Result {
        do {
            return try await completion.complete(line, cwd: cwd)
        } catch AgentPaneShellCompletion.Failure.timedOut {
            Issue.record("\(shell) completion for '\(line)' did not reply within the 60-second safety limit")
            throw AgentPaneShellCompletion.Failure.timedOut
        }
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }
}
