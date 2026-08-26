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

    func attachCommand(sessionID: LocalTmuxSessionIdentity) -> String {
        "TMUX= \(Self.restoreMarker) exec \(shellQuote(tmuxPath)) -S \(shellQuote(socketPath)) attach-session -t \(shellQuote(sessionID.rawValue))"
    }

    func hasSessionArguments(_ sessionName: String) -> [String] {
        ["-S", socketPath, "has-session", "-t", exactTarget(sessionName)]
    }

    func hasSessionArguments(sessionID: LocalTmuxSessionIdentity) -> [String] {
        ["-S", socketPath, "has-session", "-t", sessionID.rawValue]
    }

    func sessionPathArguments(sessionID: LocalTmuxSessionIdentity) -> [String] {
        ["-S", socketPath, "display-message", "-p", "-t", sessionID.rawValue, "#{session_path}"]
    }

    func sessionIdentityArguments(sessionName: String) -> [String] {
        ["-S", socketPath, "display-message", "-p", "-t", exactTarget(sessionName), "#{session_id}"]
    }

    func sessionIdentityArguments(sessionID: LocalTmuxSessionIdentity) -> [String] {
        ["-S", socketPath, "display-message", "-p", "-t", sessionID.rawValue, "#{session_id}"]
    }

    func listSessionsArguments() -> [String] {
        ["-S", socketPath, "list-sessions", "-F", "#{session_name}\t#{session_id}\t#{session_windows}\t#{session_created}"]
    }

    func listClientsArguments() -> [String] {
        ["-S", socketPath, "list-clients", "-F", "#{client_id}\t#{session_name}\t#{client_pid}\t#{client_tty}"]
    }

    func listClientsArguments(sessionID: LocalTmuxSessionIdentity) -> [String] {
        ["-S", socketPath, "list-clients", "-t", sessionID.rawValue, "-F", "#{client_id}\t#{session_name}\t#{client_pid}\t#{client_tty}"]
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

    func attachArguments(sessionID: LocalTmuxSessionIdentity) -> [String] {
        ["-S", socketPath, "attach-session", "-t", sessionID.rawValue]
    }

    func historyLimitArguments(sessionID: LocalTmuxSessionIdentity, lines: Int = 10_000) -> [String] {
        ["-S", socketPath, "set-window-option", "-t", sessionID.rawValue, "history-limit", String(lines)]
    }

    func detachArguments(sessionID: LocalTmuxSessionIdentity, clientID: String? = nil) -> [String] {
        var arguments = ["-S", socketPath, "detach-client"]
        if let clientID {
            arguments.append(contentsOf: ["-t", clientID])
        } else {
            arguments.append(contentsOf: ["-s", sessionID.rawValue])
        }
        return arguments
    }

    func killSessionArguments(sessionID: LocalTmuxSessionIdentity) -> [String] {
        ["-S", socketPath, "kill-session", "-t", sessionID.rawValue]
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
