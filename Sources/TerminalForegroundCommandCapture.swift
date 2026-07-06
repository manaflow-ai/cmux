import CMUXAgentLaunch
import Foundation

/// Resolves the shell command to save for each live terminal when capturing a
/// workspace action: the tty's foreground process argv, cleaned so re-running
/// it starts a fresh session (known agent resume flags stripped).
enum TerminalForegroundCommandCapture {

    /// Foreground, non-shell command lines keyed by the terminal's
    /// `CMUX_SURFACE_ID` (the panel UUID exported to every spawned shell).
    static func liveCommandsBySurfaceUUID() -> [UUID: String] {
        let processes = CmuxTopProcessSnapshot.allProcesses(
            includeProcessDetails: true,
            includeCMUXScope: true
        )
        var bestBySurface: [UUID: CmuxTopProcessInfo] = [:]
        for process in processes {
            guard let surfaceID = process.cmuxSurfaceID,
                  let processGroupID = process.processGroupID,
                  let terminalProcessGroupID = process.terminalProcessGroupID,
                  processGroupID == terminalProcessGroupID,
                  !isShellProcessName(process.name) else { continue }
            if let existing = bestBySurface[surfaceID] {
                if isPreferred(process, over: existing) {
                    bestBySurface[surfaceID] = process
                }
            } else {
                bestBySurface[surfaceID] = process
            }
        }

        var commands: [UUID: String] = [:]
        for (surfaceID, process) in bestBySurface {
            guard let argv = TerminalSSHSessionDetector.commandLineArguments(forPID: Int32(process.pid)),
                  let command = commandLine(fromArgv: argv),
                  !command.isEmpty else { continue }
            commands[surfaceID] = command
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
    /// verbatim (it is the form the user invoked — bare name, `./gradlew`,
    /// or an absolute path — and panes replay from their saved cwd), known
    /// agent argv goes through the shared provider-aware
    /// `AgentLaunchSanitizer` so stale session/resume artifacts never
    /// replay, and every token including the executable is shell-quoted so
    /// nothing replays as shell syntax.
    static func commandLine(fromArgv argv: [String]) -> String? {
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
