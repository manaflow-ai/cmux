import CMUXAgentLaunch
import Foundation

/// Resolves the shell command to save for each live terminal when capturing a
/// workspace action: the tty's foreground process argv, cleaned so re-running
/// it starts a fresh session (known agent resume flags stripped).
enum TerminalForegroundCommandCapture {
    /// Maximum UTF-8 byte length for a command replayed by typing it into a fresh shell.
    ///
    /// Workspace layout replay writes the command plus a newline into a just-spawned
    /// shell pty. That tty is still in canonical mode, and macOS silently discards
    /// canonical input lines beyond MAX_CANON (1024 bytes) mid-token. The 1000-byte
    /// limit leaves room for the trailing newline and shell-integration prefix bytes.
    static let maxReplayableCommandUTF8Length = 1000

    /// Foreground, non-shell command lines keyed by tty device id. Identity
    /// comes from the workspace-owned panel→tty mapping — never from the
    /// child process's ambient CMUX_* environment, which any foreground
    /// process can override or carry stale.
    static func liveCommands(forTTYDevices ttyDevices: Set<Int64>) -> [Int64: String] {
        guard !ttyDevices.isEmpty else { return [:] }
        let processes = CmuxTopProcessSnapshot.allProcesses(
            includeProcessDetails: true,
            includeCMUXScope: false
        )
        var bestByTTY: [Int64: CmuxTopProcessInfo] = [:]
        for process in processes {
            guard let ttyDevice = process.ttyDevice,
                  ttyDevices.contains(ttyDevice),
                  let processGroupID = process.processGroupID,
                  let terminalProcessGroupID = process.terminalProcessGroupID,
                  processGroupID == terminalProcessGroupID,
                  !isShellProcessName(process.name) else { continue }
            if let existing = bestByTTY[ttyDevice] {
                if isPreferred(process, over: existing) {
                    bestByTTY[ttyDevice] = process
                }
            } else {
                bestByTTY[ttyDevice] = process
            }
        }

        var commands: [Int64: String] = [:]
        for (ttyDevice, process) in bestByTTY {
            guard let argv = TerminalSSHSessionDetector.commandLineArguments(forPID: Int32(process.pid)),
                  let command = commandLine(fromArgv: argv),
                  !command.isEmpty else { continue }
            commands[ttyDevice] = command
        }
        return commands
    }

    /// Prefer the process-group leader (the command the shell launched); break
    /// ties toward the older (lower) pid.
    private static func isPreferred(_ candidate: CmuxTopProcessInfo, over existing: CmuxTopProcessInfo) -> Bool {
        let candidateIsLeader = candidate.processGroupID == candidate.pid
        let existingIsLeader = existing.processGroupID == existing.pid
        if candidateIsLeader != existingIsLeader {
            return candidateIsLeader
        }
        return candidate.pid < existing.pid
    }

    static func isShellProcessName(_ rawName: String) -> Bool {
        let name = rawName.hasPrefix("-") ? String(rawName.dropFirst()) : rawName
        return Self.shellNames.contains(name)
    }

    private static let shellNames: Set<String> = [
        "zsh", "bash", "fish", "sh", "dash", "tcsh", "csh", "ksh", "nu", "pwsh", "login",
    ]

    /// Turns a captured argv into a re-runnable one-liner. argv[0] is preserved
    /// verbatim for ordinary commands (it is the form the user invoked — bare
    /// name, `./gradlew`, or an absolute path — and panes replay from their
    /// saved cwd). node/bun-hosted known agents unwrap to the bare agent name
    /// first so replay resolves through cmux's per-surface PATH shim — but only
    /// when the argv carries cmux's own injected hook arguments, the
    /// deterministic proof the shim launched it from a bare name (a user's own
    /// script or directly-launched install is never rewritten). Known
    /// agent argv then goes through the shared provider-aware
    /// `AgentLaunchSanitizer` so stale session/resume artifacts never replay,
    /// and every token including the executable is shell-quoted so nothing
    /// replays as shell syntax.
    static func commandLine(fromArgv argv: [String]) -> String? {
        let argv = AgentLaunchSanitizer.unwrappedJavaScriptRuntimeAgentArgv(
            argv,
            isKnownAgentExecutableName: { knownAgentKind(forExecutableName: $0) != nil }
        ) ?? argv
        guard let executable = argv.first, !executable.isEmpty else { return nil }
        let executableName = (executable as NSString).lastPathComponent
        guard !executableName.isEmpty, !isShellProcessName(executableName) else { return nil }
        var sanitizedArgv = argv
        if let agentKind = knownAgentKind(forExecutableName: executableName) {
            if let sanitized = AgentLaunchSanitizer.sanitizedLaunchArguments(
                argv,
                launcher: "",
                fallbackKind: agentKind
            ) {
                sanitizedArgv = sanitized
            } else {
                // Non-restorable launch form: save the bare CLI so the action
                // starts a fresh session.
                sanitizedArgv = [executable]
            }
            // The wrapper marker (checked on the pre-sanitization argv — the
            // sanitizer strips it) proves the user launched the agent by bare
            // name and the shim resolved it to this absolute binary. Save the
            // bare name so replay routes back through the per-surface PATH
            // shim and cmux hooks are re-injected fresh; a marker-less argv
            // (user typed a path themselves) keeps its executable verbatim.
            if !sanitizedArgv.isEmpty,
               AgentLaunchSanitizer.containsCmuxWrapperInjectedHookArguments(argv) {
                sanitizedArgv[0] = executableName
            }
        }
        return sanitizedArgv.map(shellQuoted).joined(separator: " ")
    }

    /// Maps a foreground executable basename to the agent kind the shared
    /// sanitizer understands. Built-in kinds match by raw value; binaries
    /// whose basename differs from their kind (agy, cursor-agent, hermes,
    /// arch-suffixed grok builds) map explicitly. Anything else is left
    /// untouched — `RestorableAgentKind(rawValue:)` would also accept
    /// arbitrary custom ids and sanitize flags of unrelated commands.
    static func knownAgentKind(forExecutableName name: String) -> String? {
        if knownAgentExecutables.contains(name) {
            return name
        }
        if let alias = agentExecutableAliases[name] {
            return alias
        }
        if name.hasPrefix("grok-") {
            return "grok"
        }
        return nil
    }

    /// `allCases` intentionally omits the registry-owned kinds (grok, pi,
    /// antigravity) so Vault registrations can override them; the sanitizer
    /// still understands those kinds, so add their exact executables back.
    private static let knownAgentExecutables = Set(RestorableAgentKind.allCases.map(\.rawValue))
        .union(["grok", "pi", "antigravity"])

    private static let agentExecutableAliases: [String: String] = [
        "agy": "antigravity",
        "omp": "pi",
        "acli": "rovodev",
        "cursor-agent": "cursor",
        "hermes": "hermes-agent",
    ]

    private static let unquotedArgumentScalars: CharacterSet = {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "._-/=:,@+%")
        return allowed
    }()

    static func shellQuoted(_ argument: String) -> String {
        guard !argument.isEmpty else { return "''" }
        if argument.unicodeScalars.allSatisfy({ unquotedArgumentScalars.contains($0) }) {
            return argument
        }
        return "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
