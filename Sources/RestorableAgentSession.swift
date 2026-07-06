import Foundation
import CMUXAgentLaunch

nonisolated enum TerminalStartupShellQuoting {
    static func singleQuoted(_ value: String) -> String {
        if value.utf8.contains(where: { $0 >= 0x80 }) {
            return asciiPrintfCommandSubstitution(for: value)
        }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func shellToken(_ value: String, allowingBareASCII: Bool) -> String {
        if value.utf8.contains(where: { $0 >= 0x80 }) {
            return asciiPrintfCommandSubstitution(for: value)
        }
        if allowingBareASCII,
           value.range(of: "[^A-Za-z0-9_./:=+-]", options: .regularExpression) == nil {
            return value
        }
        return singleQuoted(value)
    }

    private static func asciiPrintfCommandSubstitution(for value: String) -> String {
        let octalBytes = value.utf8
            .map { String(format: #"\%03o"#, Int($0)) }
            .joined()
        return #""$(printf '"# + octalBytes + #"')""#
    }
}

fileprivate func shellSingleQuoted(_ value: String) -> String {
    TerminalStartupShellQuoting.singleQuoted(value)
}

nonisolated enum TerminalStartupWorkingDirectoryPrefix {
    static func optionalChangeDirectoryPrefix(for workingDirectory: String?) -> String? {
        guard let workingDirectory = normalized(workingDirectory) else { return nil }
        let quoted = TerminalStartupShellQuoting.singleQuoted(workingDirectory)
        // No POSIX `{ …; }` grouping: this runs verbatim in the user's login shell
        // (cmux spawns via `/usr/bin/login → $SHELL`), which may be fish — fish has no
        // brace grouping and errors before the agent launches (issue #6285). `&&`/`||`
        // are a left-associative, equal-precedence AND-OR list in sh/bash/zsh/fish, so
        // `cd … || [ ! -d … ] && cmd` == `(cd || test) && cmd` in every shell.
        return "cd -- \(quoted) 2>/dev/null || [ ! -d \(quoted) ] && "
    }

    static func prefix(_ command: String, workingDirectory: String?) -> String {
        guard let prefix = optionalChangeDirectoryPrefix(for: workingDirectory) else {
            return command
        }
        return prefix + command
    }

    static func replacingRequiredChangeDirectoryPrefix(
        in command: String,
        workingDirectory: String?
    ) -> String {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let workingDirectory = normalized(workingDirectory) else { return trimmed }
        let stripped = strippedRequiredChangeDirectoryPrefix(
            from: trimmed,
            workingDirectory: workingDirectory
        )
        let command = strippedSavedWorkingDirectoryOptions(
            from: stripped,
            workingDirectory: workingDirectory
        )
        return prefix(command, workingDirectory: workingDirectory)
    }

    static func replacingRequiredChangeDirectoryPrefix(
        in command: String,
        previousWorkingDirectory: String?,
        workingDirectory: String?
    ) -> String {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let stripped = normalized(previousWorkingDirectory).map {
            strippedSavedWorkingDirectoryOptions(
                from: strippedRequiredChangeDirectoryPrefix(from: trimmed, workingDirectory: $0),
                workingDirectory: $0
            )
        } ?? trimmed
        return replacingRequiredChangeDirectoryPrefix(
            in: stripped,
            workingDirectory: workingDirectory
        )
    }

    private static func strippedRequiredChangeDirectoryPrefix(
        from command: String,
        workingDirectory: String
    ) -> String {
        let quotedCandidates = [
            TerminalStartupShellQuoting.singleQuoted(workingDirectory),
            legacySingleQuoted(workingDirectory)
        ]
        var seen = Set<String>()
        for quoted in quotedCandidates where seen.insert(quoted).inserted {
            let prefixes = [
                "cd -- \(quoted) 2>/dev/null || [ ! -d \(quoted) ] && ",
                "{ cd -- \(quoted) 2>/dev/null || [ ! -d \(quoted) ]; } && ",
                "{ [ ! -d \(quoted) ] || cd -- \(quoted); } && ",
                "cd -- \(quoted) && ",
                "cd \(quoted) && "
            ]
            for prefix in prefixes where command.hasPrefix(prefix) {
                return String(command.dropFirst(prefix.count))
            }
        }
        return command
    }

    private static func strippedSavedWorkingDirectoryOptions(
        from command: String,
        workingDirectory: String
    ) -> String {
        let words = shellWordRanges(command)
        let ranges = savedWorkingDirectoryOptionRanges(
            in: words,
            workingDirectory: workingDirectory
        )
        guard !ranges.isEmpty else { return command }
        return removingRanges(removing: ranges, from: command)
    }

    private static func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static func legacySingleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    struct ShellWordRange {
        var value: String
        var range: Range<String.Index>
    }

    static func shellWordRanges(_ command: String) -> [ShellWordRange] {
        enum Quote {
            case single
            case double
        }

        var words: [ShellWordRange] = []
        var current = ""
        var wordStart: String.Index?
        var quote: Quote?
        var hasCurrentWord = false
        let doubleQuoteEscapable: Set<Character> = ["$", "`", "\"", "\\", "\n"]

        func markWordStart(_ index: String.Index) {
            if wordStart == nil {
                wordStart = index
            }
            hasCurrentWord = true
        }

        func finishWord(at end: String.Index) {
            guard hasCurrentWord else { return }
            words.append(ShellWordRange(value: current, range: (wordStart ?? end)..<end))
            current = ""
            wordStart = nil
            hasCurrentWord = false
        }

        var index = command.startIndex
        while index < command.endIndex {
            let character = command[index]
            switch (quote, character) {
            case (.single, "'"), (.double, "\""):
                quote = nil
            case (nil, "'"):
                markWordStart(index)
                quote = .single
            case (nil, "\""):
                markWordStart(index)
                quote = .double
            case (.double, "\\"):
                markWordStart(index)
                let next = command.index(after: index)
                if next < command.endIndex,
                   doubleQuoteEscapable.contains(command[next]) {
                    current.append(command[next])
                    index = command.index(after: next)
                    continue
                }
                current.append(character)
            case (nil, "\\"):
                markWordStart(index)
                let next = command.index(after: index)
                if next < command.endIndex {
                    current.append(command[next])
                    index = command.index(after: next)
                    continue
                }
                current.append(character)
            case (nil, " "), (nil, "\t"), (nil, "\n"):
                finishWord(at: index)
            default:
                markWordStart(index)
                current.append(character)
            }
            index = command.index(after: index)
        }
        finishWord(at: command.endIndex)
        return words
    }

    private static func savedWorkingDirectoryOptionRanges(
        in words: [ShellWordRange],
        workingDirectory: String
    ) -> [Range<String.Index>] {
        let valueOptions: Set<String> = ["--cd", "-C", "--cwd", "--workspace", "-w"]
        let optionPrefixes = valueOptions.map { "\($0)=" }
        var ranges: [Range<String.Index>] = []
        var index = 0
        while index < words.count {
            let arg = words[index].value
            if arg == "--" {
                break
            }
            if valueOptions.contains(arg),
               index + 1 < words.count,
               workingDirectoryValue(words[index + 1].value, matches: workingDirectory) {
                ranges.append(words[index].range.lowerBound..<words[index + 1].range.upperBound)
                index += 2
                continue
            }
            if let prefix = optionPrefixes.first(where: { arg.hasPrefix($0) }) {
                let value = String(arg.dropFirst(prefix.count))
                if workingDirectoryValue(value, matches: workingDirectory) {
                    ranges.append(words[index].range)
                    index += 1
                    continue
                }
            }
            index += 1
        }
        return ranges
    }

    private static func removingRanges(
        removing ranges: [Range<String.Index>],
        from command: String
    ) -> String {
        let expanded = ranges.map { range -> Range<String.Index> in
            var lower = range.lowerBound
            var upper = range.upperBound
            if lower == command.startIndex {
                while upper < command.endIndex, command[upper].isWhitespace {
                    upper = command.index(after: upper)
                }
            } else {
                while lower > command.startIndex {
                    let before = command.index(before: lower)
                    guard command[before].isWhitespace else { break }
                    lower = before
                }
            }
            return lower..<upper
        }.sorted { $0.lowerBound < $1.lowerBound }

        var merged: [Range<String.Index>] = []
        for range in expanded {
            guard let last = merged.last else {
                merged.append(range)
                continue
            }
            if range.lowerBound <= last.upperBound {
                let upper = last.upperBound < range.upperBound ? range.upperBound : last.upperBound
                merged[merged.count - 1] = last.lowerBound..<upper
            } else {
                merged.append(range)
            }
        }

        var result = ""
        var cursor = command.startIndex
        for range in merged {
            result.append(contentsOf: command[cursor..<range.lowerBound])
            cursor = range.upperBound
        }
        result.append(contentsOf: command[cursor..<command.endIndex])
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func workingDirectoryValue(_ value: String, matches workingDirectory: String) -> Bool {
        guard value == workingDirectory else {
            return (value as NSString).expandingTildeInPath == (workingDirectory as NSString).expandingTildeInPath
        }
        return true
    }
}

enum AgentResumeCommandBuilder {
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
    static func resumeShellCommand(
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

    static func forkShellCommand(
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

    private static func shellCommand(
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
        // Render the claude/codex executable as the wrapper shim token so the
        // executed command routes through cmux's `claude`/`codex` wrapper
        // (re-injecting the agent hooks) even inside the `$SHELL -lic` restore
        // launcher, where the shell integration's PATH shim / shell function are
        // not active and an `env`-prefixed invocation would otherwise hit the
        // user's real binary. Without this, an auto-resumed codex session runs the
        // bare `codex` binary, fires no SessionStart hook, and the session registry
        // never marks it live, so the iOS GUI stays read-only.
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
                quote: shellSingleQuoted
            )
        case .codex:
            shellCommand = AgentResumeArgv.renderedPortableCodexResumeShellCommand(
                parts: sanitizedCommandParts,
                quote: shellSingleQuoted
            )
        default:
            shellCommand = sanitizedCommandParts.map(shellSingleQuoted).joined(separator: " ")
        }
        return TerminalStartupWorkingDirectoryPrefix.prefix(shellCommand, workingDirectory: cwd)
    }

    static func openCodeVersionProbe(
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

    private static func launchEnvironmentParts(
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
               claudeAuthSelectionEnvironmentKeys.contains(key) {
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

    private static func resumeArguments(
        kind: RestorableAgentKind,
        sessionId: String,
        launchCommand: AgentLaunchCommandSnapshot?,
        workingDirectory: String?,
        customRegistration: CmuxVaultAgentRegistration?
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

        return AgentResumeArgv().builtInKind(
            kind: kind.rawValue,
            sessionId: sessionId,
            executablePath: launchCommand?.executablePath,
            arguments: launchCommand?.arguments ?? []
        )
    }

    private static func forkArguments(
        kind: RestorableAgentKind,
        sessionId: String,
        launchCommand: AgentLaunchCommandSnapshot?,
        workingDirectory: String?,
        customRegistration: CmuxVaultAgentRegistration?
    ) -> [String]? {
        let forkArgv = AgentForkArgv()
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

    private static func customResumeArguments(
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

    private static func customForkArguments(
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

    private static func customTemplateArguments(
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

    private static func resolveTemplatePart(
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

    private static func splitShellWords(_ command: String) -> [String] {
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

    private static func resumeWithOption(
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

    private static func commandParts(
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

    private static func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

struct SessionRestorableAgentSnapshot: Codable, Sendable {
    static let maxInlineStartupInputBytes = 900

    var kind: RestorableAgentKind
    var sessionId: String
    var workingDirectory: String?
    var launchCommand: AgentLaunchCommandSnapshot?
    var registration: CmuxVaultAgentRegistration? = nil

    var resumeCommand: String? {
        AgentResumeCommandBuilder.resumeShellCommand(
            kind: kind,
            sessionId: sessionId,
            launchCommand: launchCommand,
            workingDirectory: workingDirectory,
            registrationOverride: registration
        )
    }

    var forkCommand: String? {
        AgentResumeCommandBuilder.forkShellCommand(
            kind: kind,
            sessionId: sessionId,
            launchCommand: launchCommand,
            workingDirectory: workingDirectory,
            registrationOverride: registration
        )
    }

    func resumeStartupInput(
        fileManager: FileManager = .default,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        allowLauncherScript: Bool = true,
        allowOversizedInlineInput: Bool = false
    ) -> String? {
        startupInput(
            command: resumeCommand,
            fileManager: fileManager,
            temporaryDirectory: temporaryDirectory,
            allowLauncherScript: allowLauncherScript,
            allowOversizedInlineInput: allowOversizedInlineInput
        )
    }

    func resumeStartupCommand(
        fileManager: FileManager = .default,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) -> String? {
        guard let command = resumeCommand,
              let scriptURL = AgentResumeScriptStore.writeLauncherScript(
                  command: command,
                  kind: kind,
                  sessionId: sessionId,
                  fileManager: fileManager,
                  temporaryDirectory: temporaryDirectory,
                  returnToLoginShell: true,
                  // Match the resume command's own cd: agents with an `.ignore` cwd policy resume from
                  // the current directory (no cd), so the post-exit shell must not force the launch dir.
                  workingDirectory: registration?.cwd == .ignore
                      ? nil
                      : (workingDirectory ?? launchCommand?.workingDirectory)
              ) else {
            return nil
        }
        return "/bin/zsh \(shellSingleQuoted(scriptURL.path))"
    }

    func forkStartupInput(
        fileManager: FileManager = .default,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        allowLauncherScript: Bool = true
    ) -> String? {
        startupInput(
            command: forkCommand,
            fileManager: fileManager,
            temporaryDirectory: temporaryDirectory,
            allowLauncherScript: allowLauncherScript
        )
    }

    private func startupInput(
        command: String?,
        fileManager: FileManager,
        temporaryDirectory: URL,
        allowLauncherScript: Bool = true,
        allowOversizedInlineInput: Bool = false
    ) -> String? {
        guard let command else { return nil }
        let inlineInput = command + "\n"
        guard inlineInput.utf8.count > Self.maxInlineStartupInputBytes else {
            return inlineInput
        }
        guard !allowOversizedInlineInput else {
            return inlineInput
        }
        guard allowLauncherScript else { return nil }
        guard let scriptURL = AgentResumeScriptStore.writeLauncherScript(
            command: command,
            kind: kind,
            sessionId: sessionId,
            fileManager: fileManager,
            temporaryDirectory: temporaryDirectory
        ) else {
            return nil
        }

        let scriptInput = "/bin/zsh \(shellSingleQuoted(scriptURL.path))\n"
        return scriptInput.utf8.count <= Self.maxInlineStartupInputBytes ? scriptInput : nil
    }
}

extension SessionRestorableAgentSnapshot {
    var agentDisplayName: String {
        if let name = registration?.name.trimmingCharacters(in: .whitespacesAndNewlines),
           !name.isEmpty {
            return name
        }
        return kind.displayName
    }
}

private enum AgentResumeScriptStore {
    private static let directoryName = "cmux-agent-resume"
    private static let scriptTTL: TimeInterval = 24 * 60 * 60

    static func writeLauncherScript(
        command: String,
        kind: RestorableAgentKind,
        sessionId: String,
        fileManager: FileManager,
        temporaryDirectory: URL,
        returnToLoginShell: Bool = false,
        workingDirectory: String? = nil
    ) -> URL? {
        let directoryURL = temporaryDirectory.appendingPathComponent(directoryName, isDirectory: true)
        do {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryURL.path)
            pruneOldScripts(in: directoryURL, fileManager: fileManager)

            let safeSessionPrefix = sessionId
                .prefix(12)
                .map { character -> Character in
                    character.isLetter || character.isNumber || character == "-" ? character : "_"
                }
            let scriptURL = directoryURL.appendingPathComponent(
                "\(kind.rawValue)-\(String(safeSessionPrefix))-\(UUID().uuidString).zsh",
                isDirectory: false
            )
            var lines = [
                "#!/bin/zsh",
                "rm -f -- \"$0\" 2>/dev/null || true"
            ]
            if returnToLoginShell {
                lines.append(contentsOf: TerminalStartupReturnShellScript.commandThenReturnLines(
                    command: command,
                    workingDirectory: workingDirectory
                ))
            } else {
                lines.append(command)
            }
            let contents = lines.joined(separator: "\n") + "\n"
            try contents.write(to: scriptURL, atomically: true, encoding: .utf8)
            try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: scriptURL.path)
            return scriptURL
        } catch {
            return nil
        }
    }

    private static func pruneOldScripts(in directoryURL: URL, fileManager: FileManager) {
        guard let scriptURLs = try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        let cutoff = Date().addingTimeInterval(-scriptTTL)
        for scriptURL in scriptURLs where scriptURL.pathExtension == "zsh" {
            let values = try? scriptURL.resourceValues(forKeys: [.contentModificationDateKey])
            if let modified = values?.contentModificationDate, modified < cutoff {
                try? fileManager.removeItem(at: scriptURL)
            }
        }
    }
}

struct RestorableAgentSessionIndex: Sendable {
    static let empty = RestorableAgentSessionIndex(entriesByPanel: [:])

    struct PanelKey: Hashable, Sendable {
        let workspaceId: UUID
        let panelId: UUID
    }

    struct Entry: Sendable {
        let snapshot: SessionRestorableAgentSnapshot
        let lifecycle: AgentHibernationLifecycleState?
        let updatedAt: TimeInterval
        let processIDs: Set<Int>
    }

    enum ProcessDetectedSessionIDSource: Sendable {
        case explicit
        case inferredLatestSessionFile
    }

    typealias ProcessDetectedSnapshotEntry = (
        snapshot: SessionRestorableAgentSnapshot,
        updatedAt: TimeInterval,
        processIDs: Set<Int>,
        sessionIDSource: ProcessDetectedSessionIDSource
    )

    private struct SessionKey: Hashable {
        let kind: RestorableAgentKind
        let sessionId: String
    }

    private struct PanelKindKey: Hashable {
        let panelKey: PanelKey
        let kind: RestorableAgentKind
    }

    private let entriesByPanel: [PanelKey: Entry]
    private let entriesByPanelId: [UUID: Entry]

    private func entry(workspaceId: UUID, panelId: UUID) -> Entry? {
        entriesByPanel[PanelKey(workspaceId: workspaceId, panelId: panelId)] ?? entriesByPanelId[panelId]
    }

    func snapshot(workspaceId: UUID, panelId: UUID) -> SessionRestorableAgentSnapshot? {
        entry(workspaceId: workspaceId, panelId: panelId)?.snapshot
    }

    func lifecycle(workspaceId: UUID, panelId: UUID) -> AgentHibernationLifecycleState? {
        entry(workspaceId: workspaceId, panelId: panelId)?.lifecycle
    }

    func updatedAt(workspaceId: UUID, panelId: UUID) -> TimeInterval? {
        entry(workspaceId: workspaceId, panelId: panelId)?.updatedAt
    }

    func processIDs(workspaceId: UUID, panelId: UUID) -> Set<Int> {
        entry(workspaceId: workspaceId, panelId: panelId)?.processIDs ?? []
    }

    func hasLiveProcess(workspaceId: UUID, panelId: UUID) -> Bool {
        !processIDs(workspaceId: workspaceId, panelId: panelId).isEmpty
    }

    func liveAgentProcessFingerprint() -> Set<String> {
        Set(entriesByPanel.compactMap { key, entry in
            guard !entry.processIDs.isEmpty else { return nil }
            return [
                key.workspaceId.uuidString,
                key.panelId.uuidString,
                entry.snapshot.kind.rawValue,
                entry.snapshot.sessionId,
                entry.processIDs.sorted().map(String.init).joined(separator: ",")
            ].joined(separator: "|")
        })
    }

    // WARNING: Expensive. This reads every agent kind's hook-store file from disk,
    // resolves transcripts, and runs sysctl(KERN_PROCARGS2) per recorded session for
    // live-PID filtering (measured 350ms-1.8s on machines with large agent history).
    // NEVER call it synchronously on the main actor or in interactive paths (workspace/
    // panel/window close, SwiftUI body, didSet, menu evaluation, socket handlers). Read
    // the off-main, cached `SharedLiveAgentIndex.shared` instead. The only sanctioned
    // synchronous callers are cold-cache fallbacks guarded by a nil cache check.
    static func load(
        homeDirectory: String = NSHomeDirectory(),
        fileManager: FileManager = .default
    ) -> RestorableAgentSessionIndex {
        let registry = CmuxVaultAgentRegistry.load(homeDirectory: homeDirectory, fileManager: fileManager)
        return load(
            homeDirectory: homeDirectory,
            fileManager: fileManager,
            registry: registry,
            detectedSnapshots: [:]
        )
    }

    static func loadIncludingProcessDetectedSnapshots(
        homeDirectory: String = NSHomeDirectory(),
        fileManager: FileManager = .default
    ) async -> RestorableAgentSessionIndex {
        await Task.detached(priority: .utility) {
            loadIncludingProcessDetectedSnapshotsSynchronously(
                homeDirectory: homeDirectory,
                fileManager: fileManager
            )
        }.value
    }

    static func loadIncludingProcessDetectedSnapshotsSynchronously(
        homeDirectory: String = NSHomeDirectory(),
        fileManager: FileManager = .default
    ) -> RestorableAgentSessionIndex {
        let registry = CmuxVaultAgentRegistry.load(homeDirectory: homeDirectory, fileManager: fileManager)
        let detectedSnapshots = processDetectedSnapshots(
            registry: registry,
            fileManager: fileManager
        )
        return load(
            homeDirectory: homeDirectory,
            fileManager: fileManager,
            registry: registry,
            detectedSnapshots: detectedSnapshots
        )
    }

    static func load(
        homeDirectory: String,
        fileManager: FileManager,
        registry: CmuxVaultAgentRegistry,
        detectedSnapshots: [PanelKey: ProcessDetectedSnapshotEntry],
        processArgumentsProvider: (Int) -> CmuxTopProcessArguments? = {
            CmuxTopProcessSnapshot.processArgumentsAndEnvironment(for: $0)
        }
    ) -> RestorableAgentSessionIndex {
        let decoder = JSONDecoder()
        var resolved: [PanelKey: Entry] = [:]
        let claudeTranscriptLookup = ClaudeTranscriptLookupCache(
            homeDirectory: homeDirectory,
            fileManager: fileManager
        )
        let builtInKindIDs = Set(RestorableAgentKind.allCases.map(\.rawValue))
        let hookKinds: [(kind: RestorableAgentKind, registration: CmuxVaultAgentRegistration?)] =
            RestorableAgentKind.allCases.map { (kind: $0, registration: nil) }
            + registry.registrations.compactMap { registration in
                builtInKindIDs.contains(registration.id)
                    ? nil
                    : (kind: .custom(registration.id), registration: registration)
            }
        var hookCandidatesBySession: [SessionKey: Entry] = [:]
        var hookCandidatesByPanelAndKind: [PanelKindKey: Entry] = [:]

        for (kind, registration) in hookKinds {
            let fileURL = kind.hookStoreFileURL(homeDirectory: homeDirectory)
            guard fileManager.fileExists(atPath: fileURL.path),
                  let data = try? Data(contentsOf: fileURL),
                  let state = try? decoder.decode(RestorableAgentHookSessionStoreFile.self, from: data) else {
                continue
            }

            for record in state.sessions.values {
                var effectiveRecord = kind == .claude
                    ? resolvedClaudeWorkflowRecord(
                        record,
                        fileManager: fileManager,
                        lookup: claudeTranscriptLookup
                    )
                    : record
                // Drop untrusted launch captures before ANY derivation: the
                // working directory below would otherwise inherit the foreign launch cwd.
                effectiveRecord.launchCommand = trustedLaunchCommand(
                    effectiveRecord.launchCommand,
                    kind: kind
                )
                if kind == .codex, normalizedNonEmptyValue(effectiveRecord.launchCommand?.source)?.lowercased() == "environment", normalizedNonEmptyValue(effectiveRecord.launchCommand?.environment?["CODEX_HOME"]) == nil, (normalizedNonEmptyValue(effectiveRecord.launchCommand?.environment?["ANTHROPIC_BASE_URL"]) != nil || normalizedNonEmptyValue(effectiveRecord.launchCommand?.environment?["CLAUDE_CONFIG_DIR"]) != nil) { effectiveRecord.launchCommand = nil }
                let normalizedSessionId = effectiveRecord.sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !normalizedSessionId.isEmpty,
                      let workspaceId = UUID(uuidString: effectiveRecord.workspaceId),
                      let panelId = UUID(uuidString: effectiveRecord.surfaceId),
                      hookRecordIsRestorable(
                          effectiveRecord,
                          kind: kind,
                          fileManager: fileManager,
                          claudeTranscriptLookup: claudeTranscriptLookup
                      ) else {
                    continue
                }

                let snapshot = SessionRestorableAgentSnapshot(
                    kind: kind,
                    sessionId: normalizedSessionId,
                    workingDirectory: restorableWorkingDirectory(
                        for: effectiveRecord,
                        kind: kind,
                        registration: registration,
                        fileManager: fileManager,
                        lookup: claudeTranscriptLookup
                    ),
                    launchCommand: effectiveRecord.launchCommand,
                    registration: registration
                )
                let key = PanelKey(workspaceId: workspaceId, panelId: panelId)
                let sessionKey = SessionKey(kind: kind, sessionId: normalizedSessionId)
                let panelKindKey = PanelKindKey(panelKey: key, kind: kind)
                let liveProcessID = liveScopedProcessID(
                    for: effectiveRecord,
                    kind: kind,
                    workspaceId: workspaceId,
                    panelId: panelId,
                    processArgumentsProvider: processArgumentsProvider
                )
                let entry = Entry(
                    snapshot: snapshot,
                    lifecycle: effectiveRecord.agentLifecycle,
                    updatedAt: effectiveRecord.updatedAt,
                    processIDs: liveProcessID.map { [$0] } ?? []
                )
                if shouldReplaceHookEntry(
                    existing: hookCandidatesByPanelAndKind[panelKindKey],
                    incoming: entry
                ) {
                    hookCandidatesByPanelAndKind[panelKindKey] = entry
                }
                if shouldReplaceHookEntry(
                    existing: hookCandidatesBySession[sessionKey],
                    incoming: entry
                ) {
                    hookCandidatesBySession[sessionKey] = entry
                }
                // A saved PID is liveness evidence only. It can go stale while the
                // transcript and hook record are still restorable, so keep the
                // snapshot and leave processIDs empty when the process is gone.
                if shouldReplaceHookEntry(existing: resolved[key], incoming: entry) {
                    resolved[key] = entry
                }
            }
        }

        for (key, detected) in detectedSnapshots {
            let sameKindPanelCandidate = hookCandidatesByPanelAndKind[
                PanelKindKey(panelKey: key, kind: detected.snapshot.kind)
            ]
            if let existing = Self.matchingHookEntry(
                for: detected.snapshot,
                resolved: resolved[key],
                panelCandidate: sameKindPanelCandidate,
                sessionCandidate: hookCandidatesBySession[
                    SessionKey(kind: detected.snapshot.kind, sessionId: detected.snapshot.sessionId)
                ]
            ) {
                resolved[key] = Entry(
                    snapshot: detected.snapshot,
                    lifecycle: existing.lifecycle,
                    updatedAt: existing.updatedAt,
                    processIDs: detected.processIDs
                )
            } else if detected.sessionIDSource == .inferredLatestSessionFile,
                      let panelCandidate = sameKindPanelCandidate {
                // Latest-file detection is ambiguous when multiple panels share a cwd; preserve the exact
                // hook-store identity while still carrying live process evidence for this panel.
                resolved[key] = Entry(
                    snapshot: panelCandidate.snapshot,
                    lifecycle: panelCandidate.lifecycle,
                    updatedAt: panelCandidate.updatedAt,
                    processIDs: detected.processIDs
                )
            } else {
                resolved[key] = Entry(
                    snapshot: detected.snapshot,
                    lifecycle: nil,
                    updatedAt: 0,
                    processIDs: detected.processIDs
                )
            }
        }

        let liveDetectedSessionKeys = Set(detectedSnapshots.values.compactMap { detected -> SessionKey? in
            guard !detected.processIDs.isEmpty,
                  case .explicit = detected.sessionIDSource else {
                return nil
            }
            return SessionKey(kind: detected.snapshot.kind, sessionId: detected.snapshot.sessionId)
        })
        if !liveDetectedSessionKeys.isEmpty {
            // A live explicit detection owns the session's current panel; stale
            // hook-store records for that same session should not remain forkable.
            resolved = resolved.filter { key, entry in
                if detectedSnapshots[key] != nil {
                    return true
                }
                return !liveDetectedSessionKeys.contains(
                    SessionKey(kind: entry.snapshot.kind, sessionId: entry.snapshot.sessionId)
                )
            }
        }

        return RestorableAgentSessionIndex(entriesByPanel: resolved)
    }

    private static func matchingHookEntry(
        for snapshot: SessionRestorableAgentSnapshot,
        resolved: Entry?,
        panelCandidate: Entry?,
        sessionCandidate: Entry?
    ) -> Entry? {
        [resolved, panelCandidate, sessionCandidate].compactMap { $0 }
            .filter {
                $0.snapshot.kind == snapshot.kind &&
                    $0.snapshot.sessionId == snapshot.sessionId
            }
            .max { $0.updatedAt < $1.updatedAt }
    }

    private static func shouldReplaceHookEntry(existing: Entry?, incoming: Entry) -> Bool {
        guard let existing else {
            return true
        }
        if existing.processIDs.isEmpty && !incoming.processIDs.isEmpty {
            return true
        }
        if !existing.processIDs.isEmpty && incoming.processIDs.isEmpty {
            return false
        }
        return existing.updatedAt <= incoming.updatedAt
    }

    private static func normalizedWorkingDirectory(_ rawValue: String?) -> String? {
        normalizedNonEmptyValue(rawValue)
    }

    /// Drops launch captures that cannot describe this agent kind: a capture
    /// inherited from a different agent's session (codex started under claude
    /// carries claude's `CMUX_AGENT_LAUNCH_*`) or the hook dispatch shell's own
    /// argv. Resume/fork then fall back to the kind's bare verbs instead of
    /// rendering the foreign binary. Existing poisoned records heal on load.
    private static func trustedLaunchCommand(
        _ launchCommand: AgentLaunchCommandSnapshot?,
        kind: RestorableAgentKind
    ) -> AgentLaunchCommandSnapshot? {
        guard let launchCommand else { return nil }
        guard AgentLaunchCaptureTrust.launcherDescribesKind(launchCommand.launcher, kind: kind.rawValue),
              !AgentLaunchCaptureTrust.argvLooksLikeShellWrapper(launchCommand.arguments) else {
            return nil
        }
        return launchCommand
    }

    private static func hookRecordIsRestorable(
        _ record: RestorableAgentHookSessionRecord,
        kind: RestorableAgentKind,
        fileManager: FileManager,
        claudeTranscriptLookup: ClaudeTranscriptLookupCache
    ) -> Bool {
        if kind == .codex {
            guard record.isRestorable != false else { return false }
            guard normalizedNonEmptyValue(record.launchCommand?.source)?.lowercased() != "rejected" else { return false }
            let launchSource = normalizedNonEmptyValue(record.launchCommand?.source)?.lowercased()
            if record.isRestorable == true
                || launchSource == "default"
                || (record.launchCommand?.arguments.isEmpty == false
                    && (launchSource == nil || ["environment", "process"].contains(launchSource))
                    && !(launchSource == "environment" && normalizedNonEmptyValue(record.launchCommand?.environment?["CODEX_HOME"]) == nil && (normalizedNonEmptyValue(record.launchCommand?.environment?["ANTHROPIC_BASE_URL"]) != nil || normalizedNonEmptyValue(record.launchCommand?.environment?["CLAUDE_CONFIG_DIR"]) != nil)))
                || normalizedNonEmptyValue(record.launchCommand?.environment?["CODEX_HOME"]) != nil {
                return true
            }
            guard let transcriptPath = normalizedNonEmptyValue(record.transcriptPath) else { return false }
            return regularNonEmptyFileExists(
                atPath: (transcriptPath as NSString).expandingTildeInPath,
                fileManager: fileManager
            )
        }
        guard kind == .claude else {
            return record.isRestorable != false
        }
        if let transcriptPath = normalizedNonEmptyValue(record.transcriptPath),
           regularNonEmptyFileExists(
               atPath: (transcriptPath as NSString).expandingTildeInPath,
               fileManager: fileManager
           ) {
            return true
        }
        return claudeTranscriptExists(for: record, fileManager: fileManager, lookup: claudeTranscriptLookup)
    }

    private static func resolvedClaudeWorkflowRecord(
        _ record: RestorableAgentHookSessionRecord,
        fileManager: FileManager,
        lookup: ClaudeTranscriptLookupCache
    ) -> RestorableAgentHookSessionRecord {
        guard let sessionId = normalizedNonEmptyValue(record.sessionId),
              claudeSessionIdIsSafeFilename(sessionId) else {
            return record
        }
        if let transcriptPath = normalizedNonEmptyValue(record.transcriptPath),
           regularNonEmptyFileExists(
               atPath: (transcriptPath as NSString).expandingTildeInPath,
               fileManager: fileManager
           ) {
            return record
        }

        let roots = lookup.configRoots(for: record)
        guard !roots.isEmpty else { return record }
        let candidateProjectDirs = claudeWorkflowProjectDirs(
            for: record,
            sessionId: sessionId,
            roots: roots,
            fileManager: fileManager,
            lookup: lookup
        )
        guard let resolved = singleClaudeSiblingTranscript(
            in: candidateProjectDirs,
            excludingSessionId: sessionId,
            fileManager: fileManager
        ) else {
            return record
        }

        var resolvedRecord = record
        resolvedRecord.sessionId = resolved.sessionId
        resolvedRecord.transcriptPath = resolved.path
        return resolvedRecord
    }

    private static func claudeWorkflowProjectDirs(
        for record: RestorableAgentHookSessionRecord,
        sessionId: String,
        roots: [String],
        fileManager: FileManager,
        lookup: ClaudeTranscriptLookupCache
    ) -> [String] {
        var projectDirs: [String] = []
        var seen: Set<String> = []

        func appendIfWorkflowContainer(projectRoot: String) {
            let workflowContainer = (projectRoot as NSString).appendingPathComponent(sessionId)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: workflowContainer, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                return
            }
            let standardized = (projectRoot as NSString).standardizingPath
            guard seen.insert(standardized).inserted else { return }
            projectDirs.append(standardized)
        }

        let cwdCandidates = [
            normalizedWorkingDirectory(record.launchCommand?.workingDirectory),
            normalizedWorkingDirectory(record.cwd),
        ].compactMap { $0 }
        for root in roots {
            let projectsRoot = (root as NSString).appendingPathComponent("projects")
            for cwd in cwdCandidates {
                appendIfWorkflowContainer(
                    projectRoot: (projectsRoot as NSString).appendingPathComponent(encodeClaudeProjectDir(cwd))
                )
            }
            for projectDir in lookup.projectDirs(configRoot: root) {
                appendIfWorkflowContainer(
                    projectRoot: (projectsRoot as NSString).appendingPathComponent(projectDir)
                )
            }
        }
        return projectDirs
    }

    private static func singleClaudeSiblingTranscript(
        in projectDirs: [String],
        excludingSessionId excludedSessionId: String,
        fileManager: FileManager
    ) -> (sessionId: String, path: String)? {
        var matches: [(sessionId: String, path: String)] = []
        for projectDir in projectDirs {
            guard matches.count < 2 else { break }
            collectClaudeTranscripts(
                inDirectory: projectDir,
                excludingSessionId: excludedSessionId,
                remainingDirectoryDepth: 4,
                fileManager: fileManager,
                matches: &matches
            )
        }
        guard matches.count == 1, let match = matches.first else { return nil }
        return match
    }

    private static func collectClaudeTranscripts(
        inDirectory directory: String,
        excludingSessionId excludedSessionId: String,
        remainingDirectoryDepth: Int,
        fileManager: FileManager,
        matches: inout [(sessionId: String, path: String)]
    ) {
        guard matches.count < 2 else { return }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory, isDirectory: &isDirectory),
              isDirectory.boolValue,
              let children = try? fileManager.contentsOfDirectory(atPath: directory) else {
            return
        }
        for child in children {
            let childPath = (directory as NSString).appendingPathComponent(child)
            if child.hasSuffix(".jsonl") {
                let sessionId = String(child.dropLast(".jsonl".count))
                guard sessionId != excludedSessionId,
                      claudeSessionIdIsSafeFilename(sessionId),
                      regularNonEmptyFileExists(atPath: childPath, fileManager: fileManager) else {
                    continue
                }
                matches.append((sessionId, childPath))
                if matches.count >= 2 { return }
            } else if remainingDirectoryDepth > 0 {
                collectClaudeTranscripts(
                    inDirectory: childPath,
                    excludingSessionId: excludedSessionId,
                    remainingDirectoryDepth: remainingDirectoryDepth - 1,
                    fileManager: fileManager,
                    matches: &matches
                )
                if matches.count >= 2 { return }
            }
        }
    }

    private static func claudeTranscriptExists(
        for record: RestorableAgentHookSessionRecord,
        fileManager: FileManager,
        lookup: ClaudeTranscriptLookupCache
    ) -> Bool {
        guard let sessionId = normalizedNonEmptyValue(record.sessionId),
              claudeSessionIdIsSafeFilename(sessionId) else {
            return false
        }

        let roots = lookup.configRoots(for: record)
        guard !roots.isEmpty else { return false }

        let cwd = normalizedWorkingDirectory(record.cwd)
            ?? normalizedWorkingDirectory(record.launchCommand?.workingDirectory)
        for root in roots {
            if let cwd,
               lookup.transcriptPath(
                   configRoot: root,
                   projectDirName: encodeClaudeProjectDir(cwd),
                   sessionId: sessionId
               ) != nil {
                return true
            }
            if lookup.transcriptPathInAnyProject(
                configRoot: root,
                sessionId: sessionId
            ) != nil {
                return true
            }
        }
        return false
    }

    /// The directory cmux must `cd` into to resume or fork this session.
    ///
    /// Many agents store their session under a directory derived from the cwd the session was
    /// *launched* in (Claude `projects/<encode(cwd)>/`, plus the Grok/Pi/Gemini/Cursor/Qoder
    /// cwd-keyed buckets), and `--resume` / `--fork` only locate it from that same directory. The
    /// hook-reported `cwd` drifts when the agent `cd`s elsewhere mid-session (e.g. starting in a
    /// repo root, then moving into a worktree), so trusting it makes resume fail with "No
    /// conversation found". For directory-namespaced kinds, prefer the stable launch cwd (it matches
    /// the namespace and never drifts); for Claude, first verify which candidate actually holds the
    /// transcript. For kinds that key sessions by id and record the cwd inside the session file
    /// (Codex, OpenCode, Amp, …), keep the recorded cwd so the resumed agent reopens where it was.
    private static func restorableWorkingDirectory(
        for record: RestorableAgentHookSessionRecord,
        kind: RestorableAgentKind,
        registration: CmuxVaultAgentRegistration?,
        fileManager: FileManager,
        lookup: ClaudeTranscriptLookupCache
    ) -> String? {
        let recordedCwd = normalizedWorkingDirectory(record.cwd)
        let launchCwd = normalizedWorkingDirectory(record.launchCommand?.workingDirectory)

        // Custom Vault agents resume via their own template (which can expand {{cwd}}) and default to
        // a `.preserve` cwd policy, so keep the runtime cwd the agent was working in rather than the
        // launch dir. `.ignore` agents resume from the current directory, so the snapshot must carry
        // no saved cwd at all (downstream restore consumers read `workingDirectory` directly, not just
        // the command builder). The by-directory namespace below is only for built-in agents.
        if let registration {
            return registration.cwd == .ignore ? nil : (recordedCwd ?? launchCwd)
        }

        switch kind.cwdNamespacing {
        case .cwdInFile:
            // Resume is addressed by id and the cwd lives inside the record, so the runtime cwd is
            // fine — keeping it preserves the directory the agent was working in.
            return recordedCwd ?? launchCwd
        case .byDirectory:
            if kind == .claude,
               let verified = claudeVerifiedRestorableWorkingDirectory(
                   record: record,
                   recordedCwd: recordedCwd,
                   launchCwd: launchCwd,
                   fileManager: fileManager,
                   lookup: lookup
               ) {
                return verified
            }
            // The launch cwd matches the session namespace and never drifts; fall back to the
            // recorded cwd only when no launch cwd was captured.
            return launchCwd ?? recordedCwd
        }
    }

    /// For Claude, returns the candidate directory whose project folder actually holds the
    /// transcript — matched first against the transcript's known storage path, then against the
    /// config directory on disk — or `nil` when neither can be verified (so the caller prefers the
    /// launch cwd instead of the drift-prone recorded cwd).
    private static func claudeVerifiedRestorableWorkingDirectory(
        record: RestorableAgentHookSessionRecord,
        recordedCwd: String?,
        launchCwd: String?,
        fileManager: FileManager,
        lookup: ClaudeTranscriptLookupCache
    ) -> String? {
        guard let sessionId = normalizedNonEmptyValue(record.sessionId),
              claudeSessionIdIsSafeFilename(sessionId) else {
            return nil
        }
        let candidates = [launchCwd, recordedCwd].compactMap { $0 }

        // The transcript's own storage path names the project directory Claude will look in,
        // so the candidate whose encoding matches it is the one Claude can resume from.
        if let transcriptPath = normalizedNonEmptyValue(record.transcriptPath) {
            let expandedTranscriptPath = (transcriptPath as NSString).expandingTildeInPath
            let roots = lookup.configRoots(for: record)
            let expectedProjectDirName = claudeProjectDirName(
                containingTranscriptPath: expandedTranscriptPath,
                configRoots: roots
            ) ?? (((expandedTranscriptPath as NSString).deletingLastPathComponent) as NSString)
                .lastPathComponent
            if !expectedProjectDirName.isEmpty,
               let matched = candidates.first(where: {
                   encodeClaudeProjectDir($0) == expectedProjectDirName
               }) {
                return matched
            }
        }

        // Probe the config directory for the candidate that holds the transcript on disk.
        let roots = lookup.configRoots(for: record)
        if !roots.isEmpty {
            for candidate in candidates {
                let projectDirName = encodeClaudeProjectDir(candidate)
                for root in roots where lookup.transcriptPath(
                    configRoot: root,
                    projectDirName: projectDirName,
                    sessionId: sessionId
                ) != nil {
                    return candidate
                }
            }
        }
        return nil
    }

    private static func claudeSessionIdIsSafeFilename(_ sessionId: String) -> Bool {
        sessionId.range(of: #"[\\/]"#, options: .regularExpression) == nil
            && !sessionId.isEmpty
            && sessionId != "."
            && sessionId != ".."
    }

    static func encodeClaudeProjectDir(_ path: String) -> String {
        // Claude derives a project directory name by replacing both "/" and "." with "-"
        // (e.g. "/Users/x/repo/.claude" -> "-Users-x-repo--claude"). Missing the "." case
        // sent dotted paths to the wrong project directory.
        path.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ".", with: "-")
    }

    private static func claudeProjectDirName(containingTranscriptPath path: String, configRoots: [String]) -> String? {
        let standardizedPath = (path as NSString).standardizingPath
        for root in configRoots {
            let projectsRoot = ((root as NSString).appendingPathComponent("projects") as NSString)
                .standardizingPath
            let prefix = projectsRoot.hasSuffix("/") ? projectsRoot : projectsRoot + "/"
            guard standardizedPath.hasPrefix(prefix) else { continue }
            let relativePath = String(standardizedPath.dropFirst(prefix.count))
            guard let projectDirName = relativePath.split(separator: "/", maxSplits: 1).first,
                  !projectDirName.isEmpty else {
                continue
            }
            return String(projectDirName)
        }
        return nil
    }

    private static func claudeTranscriptPath(
        inProjectRoot projectRoot: String,
        sessionId: String,
        fileManager: FileManager
    ) -> String? {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: projectRoot, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return nil
        }

        let directPath = (projectRoot as NSString).appendingPathComponent("\(sessionId).jsonl")
        if regularNonEmptyFileExists(atPath: directPath, fileManager: fileManager) {
            return directPath
        }

        let nestedMessagesPath = (((projectRoot as NSString)
            .appendingPathComponent(sessionId) as NSString)
            .appendingPathComponent("messages") as NSString)
            .appendingPathComponent("\(sessionId).jsonl")
        if regularNonEmptyFileExists(atPath: nestedMessagesPath, fileManager: fileManager) {
            return nestedMessagesPath
        }
        return nil
    }

    private final class ClaudeTranscriptLookupCache {
        private let homeDirectory: String
        private let fileManager: FileManager
        private var defaultRoots: [String]?
        private var projectDirsByConfigRoot: [String: [String]] = [:]
        private var transcriptPathByProjectRootAndSession: [String: String] = [:]
        private var missingTranscriptPathByProjectRootAndSession: Set<String> = []
        private var transcriptPathByConfigRootAndSession: [String: String] = [:]
        private var missingTranscriptPathByConfigRootAndSession: Set<String> = []

        init(homeDirectory: String, fileManager: FileManager) {
            self.homeDirectory = homeDirectory
            self.fileManager = fileManager
        }

        func configRoots(for record: RestorableAgentHookSessionRecord) -> [String] {
            if let configured = RestorableAgentSessionIndex.normalizedNonEmptyValue(
                record.launchCommand?.environment?["CLAUDE_CONFIG_DIR"]
            ) {
                return [
                    ClaudeConfigDirectoryPath.preferredPath(
                        configured,
                        fileManager: fileManager,
                        homeDirectory: homeDirectory
                    ),
                ]
            }

            if let defaultRoots {
                return defaultRoots
            }

            var roots: [String] = []
            var seen: Set<String> = []
            func appendRoot(_ path: String) {
                let standardized = (path as NSString).standardizingPath
                guard seen.insert(standardized).inserted else { return }
                roots.append(standardized)
            }

            let accountRoot = (homeDirectory as NSString).appendingPathComponent(".codex-accounts/claude")
            if directoryExists(atPath: accountRoot),
               let accountDirs = try? fileManager.contentsOfDirectory(atPath: accountRoot) {
                for accountDir in accountDirs.sorted() {
                    appendRoot((accountRoot as NSString).appendingPathComponent(accountDir))
                }
            }
            appendRoot((homeDirectory as NSString).appendingPathComponent(".claude"))
            appendRoot(
                ClaudeConfigDirectoryPath.preferredPath(
                    (homeDirectory as NSString).appendingPathComponent(".subrouter/codex/claude"),
                    fileManager: fileManager,
                    homeDirectory: homeDirectory
                )
            )

            defaultRoots = roots
            return roots
        }

        func projectDirs(configRoot: String) -> [String] {
            let standardizedRoot = (configRoot as NSString).standardizingPath
            if let cached = projectDirsByConfigRoot[standardizedRoot] {
                return cached
            }

            let projectsRoot = (standardizedRoot as NSString).appendingPathComponent("projects")
            guard directoryExists(atPath: projectsRoot),
                  let projectDirs = try? fileManager.contentsOfDirectory(atPath: projectsRoot) else {
                projectDirsByConfigRoot[standardizedRoot] = []
                return []
            }

            projectDirsByConfigRoot[standardizedRoot] = projectDirs
            return projectDirs
        }

        func transcriptPath(configRoot: String, projectDirName: String, sessionId: String) -> String? {
            let standardizedRoot = (configRoot as NSString).standardizingPath
            let projectsRoot = (standardizedRoot as NSString).appendingPathComponent("projects")
            let projectRoot = ((projectsRoot as NSString).appendingPathComponent(projectDirName) as NSString)
                .standardizingPath
            let key = cacheKey(projectRoot, sessionId)
            if let cached = transcriptPathByProjectRootAndSession[key] {
                return cached
            }
            if missingTranscriptPathByProjectRootAndSession.contains(key) {
                return nil
            }

            let path = RestorableAgentSessionIndex.claudeTranscriptPath(
                inProjectRoot: projectRoot,
                sessionId: sessionId,
                fileManager: fileManager
            )
            if let path {
                transcriptPathByProjectRootAndSession[key] = path
            } else {
                missingTranscriptPathByProjectRootAndSession.insert(key)
            }
            return path
        }

        func transcriptPathInAnyProject(configRoot: String, sessionId: String) -> String? {
            let standardizedRoot = (configRoot as NSString).standardizingPath
            let key = cacheKey(standardizedRoot, sessionId)
            if let cached = transcriptPathByConfigRootAndSession[key] {
                return cached
            }
            if missingTranscriptPathByConfigRootAndSession.contains(key) {
                return nil
            }

            let projectsRoot = (standardizedRoot as NSString).appendingPathComponent("projects")
            guard directoryExists(atPath: projectsRoot) else {
                missingTranscriptPathByConfigRootAndSession.insert(key)
                return nil
            }

            for projectDir in projectDirs(configRoot: standardizedRoot) {
                if let path = transcriptPath(
                    configRoot: standardizedRoot,
                    projectDirName: projectDir,
                    sessionId: sessionId
                ) {
                    transcriptPathByConfigRootAndSession[key] = path
                    return path
                }
            }
            missingTranscriptPathByConfigRootAndSession.insert(key)
            return nil
        }

        private func directoryExists(atPath path: String) -> Bool {
            var isDirectory: ObjCBool = false
            return fileManager.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
        }

        private func cacheKey(_ prefix: String, _ sessionId: String) -> String {
            prefix + "\u{0}" + sessionId
        }
    }

    private static func regularNonEmptyFileExists(atPath path: String, fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              let attrs = try? fileManager.attributesOfItem(atPath: path),
              let size = attrs[.size] as? NSNumber else {
            return false
        }
        return size.intValue > 0
    }

    private static func liveScopedProcessID(
        for record: RestorableAgentHookSessionRecord,
        kind: RestorableAgentKind,
        workspaceId: UUID,
        panelId: UUID,
        processArgumentsProvider: (Int) -> CmuxTopProcessArguments?
    ) -> Int? {
        guard let pid = record.pid else {
            return nil
        }
        guard pid > 0,
              let process = processArgumentsProvider(pid),
              process.matchesCMUXScope(workspaceId: workspaceId, surfaceId: panelId) else {
            return nil
        }

        if let liveKind = normalizedProcessValue(process.environment["CMUX_AGENT_LAUNCH_KIND"]),
           liveKind.compare(kind.rawValue, options: [.caseInsensitive, .literal]) != .orderedSame {
            return nil
        }

        guard let recordedExecutable = recordedExecutableBasename(record),
              let liveExecutable = process.arguments.first.map(executableBasename) else {
            return pid
        }
        guard liveProcessExecutableMatchesRecordedAgent(
            kind: kind,
            liveExecutable: liveExecutable,
            recordedExecutable: recordedExecutable,
            arguments: process.arguments
        ) else {
            return nil
        }
        return pid
    }

    private static func liveProcessExecutableMatchesRecordedAgent(
        kind: RestorableAgentKind,
        liveExecutable: String,
        recordedExecutable: String,
        arguments: [String]
    ) -> Bool {
        if liveExecutable.compare(recordedExecutable, options: [.caseInsensitive, .literal]) == .orderedSame {
            return true
        }

        guard kind == .claude else { return false }
        let liveBase = liveExecutable.lowercased()
        guard liveBase == "node" || liveBase == "bun" else { return false }
        return arguments.dropFirst().contains { argument in
            let lowered = argument.lowercased()
            return executableBasename(argument).compare("claude", options: [.caseInsensitive, .literal]) == .orderedSame
                || lowered.contains("/.claude/")
                || lowered.contains("/claude/versions/")
        }
    }

    private static func recordedExecutableBasename(_ record: RestorableAgentHookSessionRecord) -> String? {
        let executable = normalizedProcessValue(record.launchCommand?.executablePath)
            ?? normalizedProcessValue(record.launchCommand?.arguments.first)
        return executable.map(executableBasename)
    }

    private static func executableBasename(_ value: String) -> String {
        (value as NSString).lastPathComponent
    }

    private static func normalizedProcessValue(_ value: String?) -> String? {
        normalizedNonEmptyValue(value)
    }

    private static func normalizedNonEmptyValue(_ value: String?) -> String? {
        guard let rawValue = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty else {
            return nil
        }
        return rawValue
    }

    private init(entriesByPanel: [PanelKey: Entry]) {
        self.entriesByPanel = entriesByPanel
        var entriesByPanelId: [UUID: Entry] = [:]
        for (key, entry) in entriesByPanel {
            let existing = entriesByPanelId[key.panelId]
            if existing == nil || entry.updatedAt >= (existing?.updatedAt ?? 0) {
                entriesByPanelId[key.panelId] = entry
            }
        }
        self.entriesByPanelId = entriesByPanelId
    }
}

private extension CmuxTopProcessArguments {
    func environmentUUID(forKey key: String) -> UUID? {
        guard let rawValue = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty else {
            return nil
        }
        return UUID(uuidString: rawValue)
    }
}
