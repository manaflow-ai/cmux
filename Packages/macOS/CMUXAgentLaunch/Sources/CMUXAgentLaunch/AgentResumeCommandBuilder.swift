import Foundation
import CmuxFoundation

/// Assembles the shell command an agent surface runs to resume or fork a prior
/// session, byte-faithfully matching the legacy app-side builder.
///
/// This is the pure value layer for resume/fork command assembly. It composes
/// the sibling primitives in this package: ``AgentResumeArgv`` resolves the
/// argument vector, ``AgentLaunchSanitizer`` strips/preserves CLI options,
/// ``AgentLaunchEnvironmentPolicy`` selects which captured environment to
/// re-export, and ``TerminalChangeDirectoryPrefix`` (from `CmuxFoundation`)
/// prepends the `cd`-guard. The claude kind routes its executable through
/// cmux's `claude` wrapper shim via
/// ``AgentResumeArgv/renderedPortableClaudeResumeShellCommand(parts:quote:)``.
///
/// The type is a stateless value: construct one at the call site
/// (`AgentResumeCommandBuilder()`) rather than reaching through a static
/// namespace, mirroring ``AgentResumeArgv``. It speaks package value inputs
/// (``AgentResumeKindDescriptor``, ``AgentResumeLaunchCommand``,
/// ``AgentResumeRegistrationOverride``) so it does not depend on the app-side
/// `RestorableAgentKind`/`AgentLaunchCommandSnapshot`/`CmuxVaultAgentRegistration`
/// types; the app keeps a thin forwarder that maps those onto these inputs.
public struct AgentResumeCommandBuilder: Sendable, Equatable {
    /// Creates a resume/fork command builder. The type holds no state.
    public init() {}

    /// Claude auth-selection environment keys that, when present in the captured
    /// launch environment, are re-exported and recorded so the resumed claude
    /// session keeps the same auth provider selection.
    private static let claudeAuthSelectionEnvironmentKeys: Set<String> = [
        "ANTHROPIC_API_KEY",
        "ANTHROPIC_AUTH_TOKEN",
        "ANTHROPIC_BASE_URL",
        "ANTHROPIC_MODEL",
        "ANTHROPIC_SMALL_FAST_MODEL",
        "CLAUDE_CODE_USE_BEDROCK",
        "CLAUDE_CODE_USE_VERTEX",
        "CLAUDE_CONFIG_DIR",
    ]

    /// The full shell command that resumes `sessionId`, or `nil` when the
    /// session id is blank or no resume argv can be resolved.
    public func resumeShellCommand(
        kind: AgentResumeKindDescriptor,
        sessionId: String,
        launchCommand: AgentResumeLaunchCommand?,
        workingDirectory: String?,
        registrationOverride: AgentResumeRegistrationOverride? = nil,
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

    /// The full shell command that forks `sessionId` into a new session, or
    /// `nil` when the session id is blank or no fork argv can be resolved.
    public func forkShellCommand(
        kind: AgentResumeKindDescriptor,
        sessionId: String,
        launchCommand: AgentResumeLaunchCommand?,
        workingDirectory: String?,
        registrationOverride: AgentResumeRegistrationOverride? = nil,
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

    /// The executable + arguments cmux runs to probe an OpenCode launch for its
    /// version (used to decide fork support), or `nil` for launcher variants
    /// that never probe.
    public func openCodeVersionProbe(
        launchCommand: AgentResumeLaunchCommand?
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

    private func shellCommand(
        argv: [String],
        kind: AgentResumeKindDescriptor,
        launchCommand: AgentResumeLaunchCommand?,
        workingDirectory: String?,
        customRegistration: AgentResumeRegistrationOverride?,
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
        // Render the claude executable as the wrapper shim token so the executed
        // command routes through cmux's `claude` wrapper (re-injecting the hook
        // --settings) even inside the `$SHELL -lic` restore launcher, where the
        // shell integration's PATH shim / `claude()` function are not active and an
        // `env`-prefixed invocation would otherwise hit the user's real binary.
        // The token is POSIX-only, and the launcher dispatches through the user's
        // shell (fish/csh/tcsh included), so token-bearing commands are wrapped in
        // `/bin/sh -c '…'` to parse everywhere; the cwd guard stays outside so
        // cd-prefix rewriting keeps composing.
        // https://github.com/manaflow-ai/cmux/issues/5639
        let shellCommand = kind.isClaude
            ? AgentResumeArgv.renderedPortableClaudeResumeShellCommand(parts: sanitizedCommandParts, quote: { $0.posixShellQuoted })
            : sanitizedCommandParts.map(\.posixShellQuoted).joined(separator: " ")
        return TerminalChangeDirectoryPrefix(workingDirectory: cwd).prefixing(shellCommand)
    }

    private func launchEnvironmentParts(
        kind: AgentResumeKindDescriptor,
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
            if kind.isClaude,
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
        kind: AgentResumeKindDescriptor,
        sessionId: String,
        launchCommand: AgentResumeLaunchCommand?,
        workingDirectory: String?,
        customRegistration: AgentResumeRegistrationOverride?
    ) -> [String]? {
        switch AgentResumeArgv().launcherResolution(
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

        if kind.isCustom {
            guard let customRegistration else { return nil }
            if customRegistration.isAntigravity {
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

        return AgentResumeArgv().builtInKind(
            kind: kind.rawValue,
            sessionId: sessionId,
            executablePath: launchCommand?.executablePath,
            arguments: launchCommand?.arguments ?? []
        )
    }

    private func forkArguments(
        kind: AgentResumeKindDescriptor,
        sessionId: String,
        launchCommand: AgentResumeLaunchCommand?,
        workingDirectory: String?,
        customRegistration: AgentResumeRegistrationOverride?
    ) -> [String]? {
        switch launchCommand?.launcher {
        case "claudeTeams":
            let original = commandParts(
                launchCommand: launchCommand,
                fallbackExecutable: "cmux"
            )
            var args = original.tail
            if args.first == "claude-teams" {
                args.removeFirst()
            }
            guard let preserved = AgentLaunchSanitizer.preservedClaudeTeamsLaunchArguments(args: args) else { return nil }
            return [original.executable, "claude-teams", "--resume", sessionId, "--fork-session"] + preserved
        case "codexTeams":
            let original = commandParts(
                launchCommand: launchCommand,
                fallbackExecutable: "cmux"
            )
            var args = original.tail
            if args.first == "codex-teams" {
                args.removeFirst()
            }
            guard let preserved = AgentLaunchSanitizer.preservedCodexForkArguments(args: args) else { return nil }
            return [original.executable, "codex-teams", "fork", sessionId] + preserved
        case "omo":
            let original = commandParts(
                launchCommand: launchCommand,
                fallbackExecutable: "cmux"
            )
            var args = original.tail
            if args.first == "omo" {
                args.removeFirst()
            }
            guard let preserved = AgentLaunchSanitizer.preservedArguments(kind: "opencode", args: args) else { return nil }
            return [original.executable, "omo", "--session", sessionId, "--fork"] + preserved
        case "omx", "omc":
            return nil
        default:
            break
        }

        switch kind.rawValue {
        case "claude":
            let original = commandParts(launchCommand: launchCommand, fallbackExecutable: "claude")
            guard let preserved = AgentLaunchSanitizer.preservedArguments(kind: "claude", args: original.tail) else { return nil }
            // Mirror the resume path: route through the `claude` wrapper (not the
            // captured real binary) so cmux hooks fire on the forked session.
            // See https://github.com/manaflow-ai/cmux/issues/5427.
            return ["claude", "--resume", sessionId, "--fork-session"] + preserved
        case "codex":
            let original = commandParts(launchCommand: launchCommand, fallbackExecutable: "codex")
            guard let preserved = AgentLaunchSanitizer.preservedCodexForkArguments(args: original.tail) else { return nil }
            return [original.executable, "fork", sessionId] + preserved
        case "opencode":
            let original = commandParts(launchCommand: launchCommand, fallbackExecutable: "opencode")
            guard let preserved = AgentLaunchSanitizer.preservedArguments(kind: "opencode", args: original.tail) else { return nil }
            return [original.executable, "--session", sessionId, "--fork"] + preserved
        default:
            if kind.isCustom {
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
            return nil
        }
    }

    private func customResumeArguments(
        registration: AgentResumeRegistrationOverride,
        sessionId: String,
        launchCommand: AgentResumeLaunchCommand?,
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
        registration: AgentResumeRegistrationOverride,
        sessionId: String,
        launchCommand: AgentResumeLaunchCommand?,
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
        registration: AgentResumeRegistrationOverride,
        sessionId: String,
        launchCommand: AgentResumeLaunchCommand?,
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
        launchCommand: AgentResumeLaunchCommand?,
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
        launchCommand: AgentResumeLaunchCommand?,
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
