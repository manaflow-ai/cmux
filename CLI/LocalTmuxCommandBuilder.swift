import Foundation

/// Validates names before they reach tmux's session-target parser.
struct LocalTmuxSessionNameValidator {
    func validate(_ raw: String) throws -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty,
              name.count <= 128,
              name.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else {
            throw CLIError(message: String(localized: "cli.localTmux.error.invalidName", defaultValue: "local-tmux session names must contain only letters, numbers, underscore, or dash (1–128 characters)"))
        }
        return name
    }
}

/// Builds the only shell command cmux persists for local-tmux reattachment.
struct LocalTmuxCommandBuilder {
    static let restoreMarker = "CMUX_LOCAL_TMUX=1"

    let tmuxPath: String
    let socketPath: String

    init(tmuxPath: String, socketPath: String) {
        self.tmuxPath = tmuxPath
        self.socketPath = socketPath
    }

    func attachCommand(sessionName: String) -> String {
        "TMUX= \(Self.restoreMarker) exec \(shellQuote(tmuxPath)) -S \(shellQuote(socketPath)) attach-session -t \(shellQuote(exactTarget(sessionName)))"
    }

    func hasSessionArguments(_ sessionName: String) -> [String] {
        ["-S", socketPath, "has-session", "-t", exactTarget(sessionName)]
    }

    func sessionPathArguments(_ sessionName: String) -> [String] {
        ["-S", socketPath, "display-message", "-p", "-t", exactTarget(sessionName), "#{session_path}"]
    }

    func listSessionsArguments() -> [String] {
        ["-S", socketPath, "list-sessions", "-F", "#{session_name}\t#{session_id}\t#{session_windows}\t#{session_created}"]
    }

    func listClientsArguments() -> [String] {
        ["-S", socketPath, "list-clients", "-F", "#{client_id}\t#{session_name}\t#{client_pid}\t#{client_tty}"]
    }

    func newSessionArguments(
        sessionName: String,
        workingDirectory: String,
        command: String?
    ) -> [String] {
        var arguments = ["-S", socketPath, "new-session", "-d", "-s", sessionName, "-c", workingDirectory]
        if let command, !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            arguments.append(contentsOf: ["/bin/sh", "-lc", command])
        }
        return arguments
    }

    func attachArguments(sessionName: String) -> [String] {
        ["-S", socketPath, "attach-session", "-t", exactTarget(sessionName)]
    }

    func historyLimitArguments(sessionName: String, lines: Int = 10_000) -> [String] {
        ["-S", socketPath, "set-window-option", "-t", exactTarget(sessionName), "history-limit", String(lines)]
    }

    func detachArguments(sessionName: String, clientID: String? = nil, all: Bool = false) -> [String] {
        var arguments = ["-S", socketPath, "detach-client"]
        if let clientID {
            arguments.append(contentsOf: ["-t", clientID])
        } else {
            if all { arguments.append("-a") }
            arguments.append(contentsOf: ["-s", exactTarget(sessionName)])
        }
        return arguments
    }

    func killSessionArguments(_ sessionName: String) -> [String] {
        ["-S", socketPath, "kill-session", "-t", exactTarget(sessionName)]
    }

    /// Prefixes a session target with `=` so tmux requires an exact match
    /// instead of falling back to prefix/glob resolution.
    private func exactTarget(_ sessionName: String) -> String {
        "=\(sessionName)"
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// Resolves tmux without trusting a GUI-launched process's reduced PATH.
struct LocalTmuxExecutableResolver {
    func resolve(
        environmentPath: String?,
        commonPaths: [String] = [
            "/opt/homebrew/bin/tmux",
            "/usr/local/bin/tmux",
            "/opt/local/bin/tmux",
            "/usr/bin/tmux",
            "/bin/tmux",
        ],
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> String? {
        var candidates: [String] = []
        if let environmentPath {
            for rawDirectory in environmentPath.split(separator: ":", omittingEmptySubsequences: false) {
                let directory = String(rawDirectory)
                guard directory.hasPrefix("/"), !directory.contains("\0") else { continue }
                candidates.append((directory as NSString).appendingPathComponent("tmux"))
            }
        }
        candidates.append(contentsOf: commonPaths)
        var seen = Set<String>()
        return candidates.first { candidate in
            seen.insert(candidate).inserted && isExecutable(candidate)
        }
    }
}
