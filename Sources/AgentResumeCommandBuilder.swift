import Foundation
import CMUXAgentLaunch

/// Composes the shell command that resumes or forks a restorable agent session.
///
/// A pure value type: it takes every input (kind, session id, launch snapshot,
/// working directory, custom registration) as a parameter and holds only its
/// stateless quoting/argv/prefix collaborators, injected for testability. The
/// app-coupled inputs (`RestorableAgentKind`, `AgentLaunchCommandSnapshot`,
/// `CmuxVaultAgentRegistration`) keep it app-side rather than in `CMUXAgentLaunch`.
struct AgentResumeCommandBuilder {
    private static let claudeAuthSelectionEnvironmentKeys: Set<String> = [
        "ANTHROPIC_API_KEY",
        "ANTHROPIC_AUTH_TOKEN",
        "ANTHROPIC_BASE_URL",
        "ANTHROPIC_MODEL",
        "ANTHROPIC_SMALL_FAST_MODEL",
        "CLAUDE_CODE_USE_BEDROCK",
        "CLAUDE_CODE_USE_VERTEX",
        "CLAUDE_CONFIG_DIR"
    ]

    private let shellQuoting: TerminalStartupShellQuoting
    private let resumeArgv: AgentResumeArgv
    private let forkArgv: AgentForkArgv
    private let workingDirectoryPrefix: TerminalStartupWorkingDirectoryPrefix

    init(
        shellQuoting: TerminalStartupShellQuoting = TerminalStartupShellQuoting(),
        resumeArgv: AgentResumeArgv = AgentResumeArgv(),
        forkArgv: AgentForkArgv = AgentForkArgv(),
        workingDirectoryPrefix: TerminalStartupWorkingDirectoryPrefix = TerminalStartupWorkingDirectoryPrefix()
    ) {
        self.shellQuoting = shellQuoting
        self.resumeArgv = resumeArgv
        self.forkArgv = forkArgv
        self.workingDirectoryPrefix = workingDirectoryPrefix
    }

    func resumeShellCommand(
        kind: RestorableAgentKind,
        sessionId: String,
        launchCommand: AgentLaunchCommandSnapshot?,
        workingDirectory: String?,
        registrationOverride: CmuxVaultAgentRegistration? = nil,
        includeWorkingDirectoryPrefix: Bool = true
    ) -> String? {
        let customRegistration = registrationOverride
        guard !sessionId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let argv = resumeArguments(
                  kind: kind,
                  sessionId: sessionId,
                  launchCommand: launchCommand,
                  workingDirectory: workingDirectory,
                  customRegistration: customRegistration
              ),
              !argv.isEmpty else {
            return nil
        }

        return shellCommand(
            argv: argv,
            kind: kind,
            launchCommand: launchCommand,
            workingDirectory: workingDirectory,
            customRegistration: customRegistration,
            includeWorkingDirectoryPrefix: includeWorkingDirectoryPrefix
        )
    }

    func forkShellCommand(
        kind: RestorableAgentKind,
        sessionId: String,
        launchCommand: AgentLaunchCommandSnapshot?,
        workingDirectory: String?,
        registrationOverride: CmuxVaultAgentRegistration? = nil,
        includeWorkingDirectoryPrefix: Bool = true
    ) -> String? {
        let customRegistration = registrationOverride
        guard !sessionId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let argv = forkArguments(
                  kind: kind,
                  sessionId: sessionId,
                  launchCommand: launchCommand,
                  workingDirectory: workingDirectory,
                  customRegistration: customRegistration
              ),
              !argv.isEmpty else {
            return nil
        }

        return shellCommand(
            argv: argv,
            kind: kind,
            launchCommand: launchCommand,
            workingDirectory: workingDirectory,
            customRegistration: customRegistration,
            includeWorkingDirectoryPrefix: includeWorkingDirectoryPrefix
        )
    }

    private func shellCommand(
        argv: [String],
        kind: RestorableAgentKind,
        launchCommand: AgentLaunchCommandSnapshot?,
        workingDirectory: String?,
        customRegistration: CmuxVaultAgentRegistration?,
        includeWorkingDirectoryPrefix: Bool
    ) -> String {
        var commandParts: [String] = []
        let environmentParts = launchEnvironmentParts(kind: kind, environment: launchCommand?.environment)
        if !environmentParts.isEmpty {
            commandParts.append("env")
            commandParts.append(contentsOf: environmentParts)
        }
        commandParts.append(contentsOf: argv)

        let cwd = !includeWorkingDirectoryPrefix || customRegistration?.cwd == .ignore
            ? nil
            : normalized(workingDirectory ?? launchCommand?.workingDirectory)
        let sanitizedCommandParts = customRegistration == nil
            ? AgentLaunchSanitizer.removingSavedWorkingDirectoryOptions(
                from: commandParts,
                workingDirectory: cwd
            )
            : commandParts
        // Render wrapper-managed executables as shim tokens so the executed
        // command routes through cmux's agent wrapper (re-injecting hooks) even
        // inside the `$SHELL -lic` restore launcher, where the shell
        // integration's PATH shim / shell functions are not active and an
        // `env`-prefixed invocation would otherwise hit the user's real binary.
        // The token is POSIX-only, and the launcher dispatches through the user's
        // shell (fish/csh/tcsh included), so token-bearing commands are wrapped in
        // `/bin/sh -c '…'` to parse everywhere; the cwd guard stays outside so
        // cd-prefix rewriting keeps composing.
        // https://github.com/manaflow-ai/cmux/issues/5639
        let shellCommand: String
        switch kind {
        case .claude:
            shellCommand = AgentResumeArgv.renderedPortableClaudeResumeShellCommand(
                parts: sanitizedCommandParts,
                quote: shellQuoting.singleQuoted
            )
        case .codex:
            shellCommand = AgentResumeArgv.renderedPortableCodexResumeShellCommand(
                parts: sanitizedCommandParts,
                quote: shellQuoting.singleQuoted
            )
        default:
            shellCommand = sanitizedCommandParts.map(shellQuoting.singleQuoted).joined(separator: " ")
        }
        return workingDirectoryPrefix.prefix(shellCommand, workingDirectory: cwd)
    }

    func openCodeVersionProbe(
        launchCommand: AgentLaunchCommandSnapshot?
    ) -> (executable: String, arguments: [String])? {
        switch launchCommand?.launcher {
        case "omo":
            return nil
        case "omx", "omc":
            return nil
        default:
            let original = commandParts(launchCommand: launchCommand, fallbackExecutable: "opencode")
            return (original.executable, ["--version"])
        }
    }

    private func launchEnvironmentParts(
        kind: RestorableAgentKind,
        environment: [String: String]?
    ) -> [String] {
        guard let environment, !environment.isEmpty else {
            return []
        }

        var environmentParts: [String] = []
        var preservedClaudeAuthSelectionEnvironmentKeys: [String] = []
        let selectedEnvironment = AgentLaunchEnvironmentPolicy.selectedEnvironment(from: environment, kind: kind.rawValue)
        for key in selectedEnvironment.keys.sorted() {
            guard let value = selectedEnvironment[key] else { continue }
            environmentParts.append("\(key)=\(value)")
            if kind == .claude,
               Self.claudeAuthSelectionEnvironmentKeys.contains(key) {
                preservedClaudeAuthSelectionEnvironmentKeys.append(key)
            }
        }
        if !preservedClaudeAuthSelectionEnvironmentKeys.isEmpty {
            environmentParts.append("CMUX_PRESERVE_CLAUDE_AUTH_SELECTION_ENV=1")
            environmentParts.append(
                "CMUX_PRESERVE_CLAUDE_AUTH_SELECTION_ENV_KEYS=\(preservedClaudeAuthSelectionEnvironmentKeys.joined(separator: ","))"
            )
        }
        return environmentParts
    }

    private func resumeArguments(
        kind: RestorableAgentKind,
        sessionId: String,
        launchCommand: AgentLaunchCommandSnapshot?,
        workingDirectory: String?,
        customRegistration: CmuxVaultAgentRegistration?
    ) -> [String]? {
        switch resumeArgv.launcherResolution(
            launcher: launchCommand?.launcher,
            sessionId: sessionId,
            executablePath: launchCommand?.executablePath,
            arguments: launchCommand?.arguments ?? []
        ) {
        case .resolved(let argv):
            return argv
        case .passthrough:
            break
        }

        if case .custom = kind {
            guard let customRegistration else { return nil }
            if customRegistration.id == CmuxVaultAgentRegistration.builtInAntigravity.id {
                return resumeWithOption(
                    kind: "antigravity",
                    launchCommand: launchCommand,
                    fallbackExecutable: customRegistration.defaultExecutable,
                    option: "--conversation",
                    sessionId: sessionId
                )
            }
            let arguments = customResumeArguments(
                registration: customRegistration,
                sessionId: sessionId,
                launchCommand: launchCommand,
                workingDirectory: workingDirectory
            )
            return arguments.isEmpty ? nil : arguments
        }

        return resumeArgv.builtInKind(
            kind: kind.rawValue,
            sessionId: sessionId,
            executablePath: launchCommand?.executablePath,
            arguments: launchCommand?.arguments ?? []
        )
    }

    private func forkArguments(
        kind: RestorableAgentKind,
        sessionId: String,
        launchCommand: AgentLaunchCommandSnapshot?,
        workingDirectory: String?,
        customRegistration: CmuxVaultAgentRegistration?
    ) -> [String]? {
        switch forkArgv.launcherResolution(
            launcher: launchCommand?.launcher,
            sessionId: sessionId,
            executablePath: launchCommand?.executablePath,
            arguments: launchCommand?.arguments ?? []
        ) {
        case .resolved(let argv):
            return argv
        case .passthrough:
            break
        }

        if case .custom = kind {
            // Custom Vault agents fork via their registration's `forkCommand`
            // template (nil when the agent has no fork capability).
            guard let customRegistration else { return nil }
            let arguments = customForkArguments(
                registration: customRegistration,
                sessionId: sessionId,
                launchCommand: launchCommand,
                workingDirectory: workingDirectory
            )
            return arguments.isEmpty ? nil : arguments
        }

        return forkArgv.builtInKind(
            kind: kind.rawValue,
            sessionId: sessionId,
            executablePath: launchCommand?.executablePath,
            arguments: launchCommand?.arguments ?? []
        )
    }

    private func customResumeArguments(
        registration: CmuxVaultAgentRegistration,
        sessionId: String,
        launchCommand: AgentLaunchCommandSnapshot?,
        workingDirectory: String?
    ) -> [String] {
        customTemplateArguments(
            template: registration.resumeCommand,
            registration: registration,
            sessionId: sessionId,
            launchCommand: launchCommand,
            workingDirectory: workingDirectory
        )
    }

    /// Builds the fork argv from a custom agent's `forkCommand` template, or
    /// returns empty when the agent declares no fork capability.
    private func customForkArguments(
        registration: CmuxVaultAgentRegistration,
        sessionId: String,
        launchCommand: AgentLaunchCommandSnapshot?,
        workingDirectory: String?
    ) -> [String] {
        guard let forkCommand = normalized(registration.forkCommand) else { return [] }
        return customTemplateArguments(
            template: forkCommand,
            registration: registration,
            sessionId: sessionId,
            launchCommand: launchCommand,
            workingDirectory: workingDirectory
        )
    }

    private func customTemplateArguments(
        template: String,
        registration: CmuxVaultAgentRegistration,
        sessionId: String,
        launchCommand: AgentLaunchCommandSnapshot?,
        workingDirectory: String?
    ) -> [String] {
        let templateParts = splitShellWords(template)
        guard !templateParts.isEmpty else { return [] }
        let original = commandParts(
            launchCommand: launchCommand,
            fallbackExecutable: registration.defaultExecutable
        )
        let sessionDirectory = normalized(registration.sessionDirectory).map {
            ($0 as NSString).expandingTildeInPath
        }
        let replacements: [String: String] = [
            "sessionId": sessionId,
            "sessionPath": sessionId,
            "executable": original.executable,
            "cwd": normalized(workingDirectory ?? launchCommand?.workingDirectory) ?? "",
            "sessionDir": sessionDirectory ?? "",
        ]
        var resolved: [String] = []
        for part in templateParts {
            guard let value = resolveTemplatePart(part, replacements: replacements) else { return [] }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return [] }
            resolved.append(trimmed)
        }
        return resolved
    }

    private func resolveTemplatePart(
        _ part: String,
        replacements: [String: String]
    ) -> String? {
        var resolved = ""
        var searchStart = part.startIndex
        while let opening = part[searchStart...].range(of: "{{") {
            resolved.append(contentsOf: part[searchStart..<opening.lowerBound])
            guard let closing = part[opening.upperBound...].range(of: "}}") else {
                resolved.append(contentsOf: part[opening.lowerBound...])
                return resolved
            }
            let key = String(part[opening.upperBound..<closing.lowerBound])
            if let replacement = replacements[key] {
                if replacement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return nil
                }
                resolved += replacement
            } else {
                resolved.append(contentsOf: part[opening.lowerBound..<closing.upperBound])
            }
            searchStart = closing.upperBound
        }
        resolved.append(contentsOf: part[searchStart...])
        return resolved
    }

    private func splitShellWords(_ command: String) -> [String] {
        enum Quote {
            case single
            case double
        }

        var words: [String] = []
        var current = ""
        var quote: Quote?
        var escaping = false

        func finishWord() {
            guard !current.isEmpty else { return }
            words.append(current)
            current = ""
        }

        for character in command {
            if escaping {
                current.append(character)
                escaping = false
                continue
            }
            if character == "\\" {
                escaping = true
                continue
            }
            switch (quote, character) {
            case (.single, "'"), (.double, "\""):
                quote = nil
            case (nil, "'"):
                quote = .single
            case (nil, "\""):
                quote = .double
            case (nil, " "), (nil, "\t"), (nil, "\n"):
                finishWord()
            default:
                current.append(character)
            }
        }
        if escaping {
            current.append("\\")
        }
        finishWord()
        return words
    }

    private func resumeWithOption(
        kind: String,
        launchCommand: AgentLaunchCommandSnapshot?,
        fallbackExecutable: String,
        option: String,
        sessionId: String
    ) -> [String]? {
        let original = commandParts(launchCommand: launchCommand, fallbackExecutable: fallbackExecutable)
        guard let preserved = AgentLaunchSanitizer.preservedArguments(kind: kind, args: original.tail) else {
            return nil
        }
        return [original.executable, option, sessionId] + preserved
    }

    private func commandParts(
        launchCommand: AgentLaunchCommandSnapshot?,
        fallbackExecutable: String
    ) -> (executable: String, tail: [String]) {
        let arguments = launchCommand?.arguments ?? []
        let executable = normalized(launchCommand?.executablePath)
            ?? arguments.first
            ?? fallbackExecutable
        let tail = arguments.isEmpty ? [] : Array(arguments.dropFirst())
        return (executable, tail)
    }

    private func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
