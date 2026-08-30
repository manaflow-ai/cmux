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
    static let serverIdentityOption = "@cmux_local_server_id"
    static let identityMismatchCommand = "run-shell false"

    let tmuxPath: String
    let socketPath: String

    init(tmuxPath: String, socketPath: String) {
        self.tmuxPath = tmuxPath
        self.socketPath = socketPath
    }

    func attachCommand(binding: LocalTmuxSessionBinding) -> String {
        let condition = serverIdentityCondition(binding)
        let action = tmuxCommand("attach-session", "-t", binding.sessionID.rawValue)
        return "TMUX= \(Self.restoreMarker) exec \(shellQuote(tmuxPath)) -S \(shellQuote(socketPath)) if-shell -F \(shellQuote(condition)) \(shellQuote(action)) \(shellQuote(Self.identityMismatchCommand))"
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

    func ensureServerIdentityArguments(candidate: UUID) -> [String] {
        [
            "-S", socketPath, "set-option", "-soq",
            Self.serverIdentityOption, candidate.uuidString.lowercased(),
        ]
    }

    func sessionBindingArguments(sessionName: String) -> [String] {
        ["-S", socketPath, "display-message", "-p", "-t", exactTarget(sessionName), sessionBindingFormat]
    }

    func sessionBindingArguments(sessionID: LocalTmuxSessionIdentity) -> [String] {
        ["-S", socketPath, "display-message", "-p", "-t", sessionID.rawValue, sessionBindingFormat]
    }

    func listSessionsArguments() -> [String] {
        [
            "-S", socketPath, "list-sessions", "-F",
            "\(sessionBindingFormat)\t#{session_windows}",
        ]
    }

    func listClientsArguments() -> [String] {
        ["-S", socketPath, "list-clients", "-F", "#{client_id}\t#{session_name}\t#{client_pid}\t#{client_tty}"]
    }

    func listClientsArguments(binding: LocalTmuxSessionBinding) -> [String] {
        guardedArguments(
            binding: binding,
            action: tmuxCommand(
                "list-clients", "-t", binding.sessionID.rawValue,
                "-F", "#{client_id}\t#{session_name}\t#{client_pid}\t#{client_tty}"
            )
        )
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

    func attachArguments(binding: LocalTmuxSessionBinding) -> [String] {
        guardedArguments(
            binding: binding,
            action: tmuxCommand("attach-session", "-t", binding.sessionID.rawValue)
        )
    }

    func historyLimitArguments(binding: LocalTmuxSessionBinding, lines: Int = 10_000) -> [String] {
        guardedArguments(
            binding: binding,
            action: tmuxCommand(
                "set-window-option", "-t", binding.sessionID.rawValue,
                "history-limit", String(lines)
            )
        )
    }

    func detachArguments(binding: LocalTmuxSessionBinding, clientID: String? = nil) -> [String] {
        let action = if let clientID {
            tmuxCommand("detach-client", "-t", clientID)
        } else {
            tmuxCommand("detach-client", "-s", binding.sessionID.rawValue)
        }
        return guardedArguments(binding: binding, action: action)
    }

    func killSessionArguments(binding: LocalTmuxSessionBinding) -> [String] {
        guardedArguments(
            binding: binding,
            action: tmuxCommand("kill-session", "-t", binding.sessionID.rawValue)
        )
    }

    private var sessionBindingFormat: String {
        "#{session_name}\t#{session_id}\t#{\(Self.serverIdentityOption)}\t#{session_created}"
    }

    private func guardedArguments(
        binding: LocalTmuxSessionBinding,
        action: String
    ) -> [String] {
        [
            "-S", socketPath, "if-shell", "-F", serverIdentityCondition(binding),
            action, Self.identityMismatchCommand,
        ]
    }

    private func serverIdentityCondition(_ binding: LocalTmuxSessionBinding) -> String {
        "#{==:#{\(Self.serverIdentityOption)},\(binding.serverID.uuidString.lowercased())}"
    }

    private func tmuxCommand(_ arguments: String...) -> String {
        arguments.map(shellQuote).joined(separator: " ")
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
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
        isDirectory: (String) -> Bool = { path in
            var directory = ObjCBool(false)
            return FileManager.default.fileExists(atPath: path, isDirectory: &directory)
                && directory.boolValue
        }
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
            seen.insert(candidate).inserted
                && !isDirectory(candidate)
                && isExecutable(candidate)
        }
    }
}
