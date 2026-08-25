import CMUXAgentLaunch
import Darwin
import Foundation

extension SurfaceResumeBindingSnapshot {
    var startupCommand: String {
        command
    }

    static func sanitizedStartupCommand(
        _ command: String,
        cwd: String?,
        source: String?,
        agentKind: String?
    ) -> String {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard source == "agent-hook" else { return trimmed }
        return TerminalStartupWorkingDirectoryPrefix.replacingRequiredChangeDirectoryPrefix(
            in: trimmed,
            workingDirectory: cwd,
            agentKind: agentKind
        )
    }

    func inlineStartupInput(
        repairPortableAgentExecutable: Bool,
        includeWorkingDirectoryPrefix: Bool = true,
        registration: CmuxVaultAgentRegistration? = nil
    ) -> String? {
        guard restoreWorkingDirectorySelection?.permitsResume != false else {
            return nil
        }
        let resolvedCommand: String
        if let selection = restoreWorkingDirectorySelection,
           selection.discardsRecordedCwdOptions {
            guard let constrainedCommand = constrainedRestoreCommand(
                selection: selection,
                includeWorkingDirectoryPrefix: includeWorkingDirectoryPrefix,
                registration: registration
            ) else {
                return nil
            }
            resolvedCommand = constrainedCommand
        } else {
            resolvedCommand = resolvedStartupCommand(
                repairPortableAgentExecutable: repairPortableAgentExecutable
            )
        }
        let command = includeWorkingDirectoryPrefix
            ? resolvedCommand
            : TerminalStartupWorkingDirectoryPrefix.removingRequiredChangeDirectoryPrefix(
                from: resolvedCommand,
                workingDirectory: cwd
            )
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let environment, !environment.isEmpty else {
            return trimmed + "\n"
        }
        let assignments = environment.keys.sorted().compactMap { key -> String? in
            guard let value = environment[key] else { return nil }
            return "\(key)=\(value)"
        }
        let argv = ["/usr/bin/env"] + assignments + ["/bin/zsh", "-lc", trimmed]
        return argv.map(Self.shellSingleQuoted).joined(separator: " ") + "\n"
    }

    func restoreStartupInput(
        repairPortableAgentExecutable: Bool
    ) -> String? {
        if usesLocalRestoreVerb {
            return localRestoreCLIInput
        }
        return inlineStartupInput(
            repairPortableAgentExecutable: repairPortableAgentExecutable
        )
    }

    func remoteStartupInput(
        registration: CmuxVaultAgentRegistration? = nil
    ) -> String? {
        inlineStartupInput(
            repairPortableAgentExecutable: false,
            registration: registration
        )
    }

    private var localRestoreCLIInput: String {
        let executable = AgentRestoreLaunch.cliStartupExecutableToken
        if let kind = Self.restoreCLIArgument(kind),
           let checkpointId = Self.restoreCLIArgument(checkpointId) {
            return " \(executable) restore \(kind) \(checkpointId)\n"
        }
        return " \(executable) restore --surface\n"
    }

    private static func restoreCLIArgument(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return AgentRestoreCLIArgument(rawValue: value)?.rawValue
    }

    private func resolvedStartupCommand(repairPortableAgentExecutable: Bool) -> String {
        guard isAgentHookBinding else {
            return startupCommand
        }
        let suppressed = SurfaceResumeCommandCanonicalizer.insertingCodexUpdateCheckSuppression(
            in: startupCommand,
            kind: kind
        )
        let repaired: String
        if repairPortableAgentExecutable {
            repaired = SurfaceResumeCommandCanonicalizer.replacingPortableAgentExecutable(
                in: suppressed,
                kind: kind
            )
        } else {
            repaired = suppressed
        }
        guard let restoreLaunch = AgentRestoreLaunch(kind: kind, sessionID: checkpointId) else { return repaired }
        return restoreLaunch.applying(toStoredCommand: repaired)
    }
}

extension AgentRestoreLaunch {
    func applying(toStoredCommand command: String) -> String {
        let words = TerminalStartupWorkingDirectoryPrefix.shellWordRanges(command)
        guard let executableIndex = SurfaceResumeCommandCanonicalizer.commandExecutableWordIndex(
            in: words,
            command: command
        ) else { return command }
        let wrapperToken = wrapperShellExecutableToken
        let executable = words[executableIndex].value
        guard command.contains(wrapperToken) || (executable as NSString).lastPathComponent == executableName else {
            return command
        }
        let routed = command.contains(wrapperToken) ? command : SurfaceResumeCommandCanonicalizer.replacingExecutableWithWrapperShellCommand(
            in: command,
            words: words,
            commandStartIndex: SurfaceResumeCommandCanonicalizer.commandStartWordIndex(in: words),
            executableIndex: executableIndex,
            wrapperToken: wrapperToken,
            customExecutableEnvironment: executable == executableName
                ? nil
                : (customExecutablePathEnvironmentKey, executable),
            wrapInPortableShell: { portableWrapperShellCommand(posixCommand: $0) }
        )
        let routedWords = TerminalStartupWorkingDirectoryPrefix.shellWordRanges(routed)
        guard let routedExecutableIndex = SurfaceResumeCommandCanonicalizer.commandExecutableWordIndex(
            in: routedWords,
            command: routed
        ) else { return command }
        let executableStart = routedWords[routedExecutableIndex].range.lowerBound
        return authorizing(
            leadingShell: String(routed[..<executableStart]),
            routedCommand: String(routed[executableStart...])
        )
    }
}

extension SurfaceResumeCommandCanonicalizer {
    static func replacingPortableAgentExecutable(in command: String, kind: String?) -> String {
        let words = TerminalStartupWorkingDirectoryPrefix.shellWordRanges(command)
        guard let executableIndex = commandExecutableWordIndex(in: words, command: command) else { return command }
        let executable = words[executableIndex].value
        guard executable.hasPrefix("/") else { return command }
        let executableBasename = (executable as NSString).lastPathComponent
        guard let executableName = portableAgentExecutableName(
                for: kind,
                executableBasename: executableBasename
              ),
              executableBasename == executableName,
              isPATHManagedAgentExecutablePath(executable, executableName: executableName) else {
            return command
        }
        guard !isExecutableFile(atPath: executable) else { return command }

        if executableName == "claude" {
            return replacingStaleWrapperRoutedExecutable(
                in: command,
                words: words,
                executableIndex: executableIndex,
                executableName: "claude",
                wrapperToken: AgentResumeArgv.claudeWrapperShellExecutableToken,
                renderPortable: { AgentResumeArgv.renderedPortableClaudeResumeShellCommand(parts: $0, quote: $1) },
                wrapInPortableShell: { AgentResumeArgv.portableClaudeResumeShellCommand(posixCommand: $0) }
            )
        } else if executableName == "codex" {
            return replacingStaleWrapperRoutedExecutable(
                in: command,
                words: words,
                executableIndex: executableIndex,
                executableName: "codex",
                wrapperToken: AgentResumeArgv.codexWrapperShellExecutableToken,
                renderPortable: { AgentResumeArgv.renderedPortableCodexResumeShellCommand(parts: $0, quote: $1) },
                wrapInPortableShell: { AgentResumeArgv.portableCodexResumeShellCommand(posixCommand: $0) }
            )
        } else {
            return replacingExecutableOnly(
                in: command,
                words: words,
                executableIndex: executableIndex,
                executableName: executableName
            )
        }
    }

    private static func portableAgentExecutableName(for kind: String?, executableBasename: String) -> String? {
        let normalizedKind = kind?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let normalizedKind, !normalizedKind.isEmpty {
            return portableAgentExecutableName(for: normalizedKind)
        }
        return portableAgentExecutableName(forExecutableBasename: executableBasename)
    }
    private static func portableAgentExecutableName(for kind: String?) -> String? {
        switch kind?.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "claude": return "claude"
        case "codex": return "codex"
        default: return nil
        }
    }
    private static func portableAgentExecutableName(forExecutableBasename basename: String) -> String? {
        portableAgentExecutableName(for: basename)
    }

    private static func isPATHManagedAgentExecutablePath(_ path: String, executableName: String) -> Bool {
        let standardized = (path as NSString).standardizingPath
        let components = standardized.split(separator: "/").map(String.init)
        if components.contains("cmux-cli-shims") {
            return isLocalManagedAgentExecutableCandidate(standardized) ||
                standardized.hasPrefix("/tmp/") ||
                standardized.hasPrefix("/private/tmp/")
        }
        guard isLocalManagedAgentExecutableCandidate(standardized) else { return false }
        let lastThree = Array(components.suffix(3))
        if lastThree == [".local", "bin", executableName]
            || lastThree == [".bun", "bin", executableName]
            || lastThree == [".volta", "bin", executableName]
            || lastThree == [".asdf", "shims", executableName] {
            return true
        }
        let lastFour = Array(components.suffix(4))
        if lastFour == [".nvm", "current", "bin", executableName]
            || lastFour == [".fnm", "current", "bin", executableName] {
            return true
        }
        let lastFive = Array(components.suffix(5))
        if lastFive == [".local", "share", "mise", "shims", executableName] {
            return true
        }
        if components.count >= 6,
           Array(components.suffix(2)) == ["bin", executableName],
           components.contains(".nvm"),
           components.contains("versions"),
           components.contains("node") {
            return true
        }
        if components.count >= 6,
           lastThree == ["installation", "bin", executableName],
           components.contains("fnm"),
           components.contains("node-versions") {
            return true
        }
        return false
    }

    private static func isLocalManagedAgentExecutableCandidate(_ standardizedPath: String) -> Bool {
        [
            FileManager.default.homeDirectoryForCurrentUser.path,
            FileManager.default.temporaryDirectory.path,
        ]
        .map { ($0 as NSString).standardizingPath }
        .contains { root in
            standardizedPath == root || standardizedPath.hasPrefix(root + "/")
        }
    }
    private static func isExecutableFile(atPath path: String) -> Bool {
        path.withCString { access($0, X_OK) == 0 }
    }

    private static func replacingStaleWrapperRoutedExecutable(
        in command: String,
        words: [TerminalStartupWorkingDirectoryPrefix.ShellWordRange],
        executableIndex: Int,
        executableName: String,
        wrapperToken: String,
        renderPortable: ([String], (String) -> String) -> String,
        wrapInPortableShell: (String) -> String
    ) -> String {
        let commandStartIndex = commandStartWordIndex(in: words)
        guard commandStartIndex < words.count,
              executableIndex >= commandStartIndex else {
            return command
        }
        var parts = Array(words[commandStartIndex...].map(\.value))
        guard !containsShellControlSyntax(
            words: words,
            command: command,
            commandStartIndex: commandStartIndex
        ) else {
            return replacingExecutableWithWrapperShellCommand(
                in: command,
                words: words,
                commandStartIndex: commandStartIndex,
                executableIndex: executableIndex,
                wrapperToken: wrapperToken,
                wrapInPortableShell: wrapInPortableShell
            )
        }
        guard canRenderStaleCommandAsPortableArgv(
            words: words,
            command: command,
            commandStartIndex: commandStartIndex,
            executableIndex: executableIndex
        ) else {
            return replacingExecutableWithWrapperShellCommand(
                in: command,
                words: words,
                commandStartIndex: commandStartIndex,
                executableIndex: executableIndex,
                wrapperToken: wrapperToken,
                wrapInPortableShell: wrapInPortableShell
            )
        }
        parts[executableIndex - commandStartIndex] = executableName
        let renderedCommand = renderPortable(parts, shellQuoted)
        let commandStart = words[commandStartIndex].range.lowerBound
        return String(command[..<commandStart]) + renderedCommand
    }

    fileprivate static func replacingExecutableWithWrapperShellCommand(
        in command: String,
        words: [TerminalStartupWorkingDirectoryPrefix.ShellWordRange],
        commandStartIndex: Int,
        executableIndex: Int,
        wrapperToken: String,
        customExecutableEnvironment: (key: String, value: String)? = nil,
        wrapInPortableShell: (String) -> String
    ) -> String {
        let renderedParts = words[commandStartIndex...].indices.map { index in
            if index == executableIndex {
                let customPath = customExecutableEnvironment.map {
                    "\($0.key)=\(shellQuoted($0.value)) "
                } ?? ""
                return customPath + wrapperToken
            }
            return renderedPortableShellWord(words[index], in: command)
        }
        let renderedCommand = wrapInPortableShell(renderedParts.joined(separator: " "))
        let commandStart = words[commandStartIndex].range.lowerBound
        return String(command[..<commandStart]) + renderedCommand
    }

    private static func renderedPortableShellWord(
        _ word: TerminalStartupWorkingDirectoryPrefix.ShellWordRange,
        in command: String
    ) -> String {
        let rawWord = String(command[word.range])
        if containsUnquotedShellControlSyntax(rawWord) {
            return rawWord
        }
        if let renderedAssignment = renderedEnvironmentAssignment(word, in: command) {
            return renderedAssignment
        }
        return shellQuoted(word.value)
    }

    private static func renderedEnvironmentAssignment(
        _ word: TerminalStartupWorkingDirectoryPrefix.ShellWordRange,
        in command: String
    ) -> String? {
        guard isEnvironmentAssignmentSyntax(word, in: command),
              let equals = word.value.firstIndex(of: "=") else {
            return nil
        }
        let name = String(word.value[..<equals])
        let valueStart = word.value.index(after: equals)
        return "\(name)=\(shellQuoted(String(word.value[valueStart...])))"
    }

    private static func canRenderStaleCommandAsPortableArgv(
        words: [TerminalStartupWorkingDirectoryPrefix.ShellWordRange],
        command: String,
        commandStartIndex: Int,
        executableIndex: Int
    ) -> Bool {
        if commandStartIndex == executableIndex {
            return true
        }
        guard commandStartIndex < words.count,
              words[commandStartIndex].value == "env" || words[commandStartIndex].value == "/usr/bin/env",
              commandStartIndex < executableIndex else {
            return false
        }
        return words[(commandStartIndex + 1)..<executableIndex].allSatisfy {
            isEnvironmentAssignmentArgument($0)
        }
    }

    private static func replacingExecutableOnly(
        in command: String,
        words: [TerminalStartupWorkingDirectoryPrefix.ShellWordRange],
        executableIndex: Int,
        executableName: String
    ) -> String {
        var repaired = command
        repaired.replaceSubrange(words[executableIndex].range, with: shellQuoted(executableName))
        return repaired
    }

    private static func containsShellControlSyntax(
        words: [TerminalStartupWorkingDirectoryPrefix.ShellWordRange],
        command: String,
        commandStartIndex: Int
    ) -> Bool {
        guard commandStartIndex < words.count else { return false }
        return words[commandStartIndex...].contains {
            containsUnquotedShellControlSyntax(String(command[$0.range]))
        }
    }

    private static func containsUnquotedShellControlSyntax(_ word: String) -> Bool {
        var quote: Character?
        var escaped = false
        var index = word.startIndex
        while index < word.endIndex {
            let character = word[index]
            if escaped {
                escaped = false
                index = word.index(after: index)
                continue
            }
            if let currentQuote = quote {
                if currentQuote == "\"", character == "\\" {
                    let next = word.index(after: index)
                    if next < word.endIndex,
                       ["$", "`", "\"", "\\", "\n"].contains(word[next]) {
                        index = word.index(after: next)
                        continue
                    }
                }
                if character == currentQuote {
                    quote = nil
                }
            } else if character == "'" || character == "\"" {
                quote = character
            } else if character == "\\" {
                escaped = true
            } else if [";", "|", "&", "<", ">", "(", ")"].contains(character) {
                return true
            }
            index = word.index(after: index)
        }
        return false
    }

    static func commandExecutableWordIndex(
        in words: [TerminalStartupWorkingDirectoryPrefix.ShellWordRange],
        command: String
    ) -> Int? {
        var index = commandStartWordIndex(in: words)
        guard index < words.count else { return nil }
        while index < words.count, isEnvironmentAssignmentSyntax(words[index], in: command) {
            index += 1
        }
        guard index < words.count else { return nil }
        if words[index].value == "env" || words[index].value == "/usr/bin/env" {
            index += 1
            while index < words.count, isEnvironmentAssignmentArgument(words[index]) {
                index += 1
            }
        }
        return index < words.count ? index : nil
    }

    fileprivate static func commandStartWordIndex(
        in words: [TerminalStartupWorkingDirectoryPrefix.ShellWordRange]
    ) -> Int {
        if let guardEndIndex = leadingWorkingDirectoryGuardEndIndex(in: words) {
            return guardEndIndex + 1
        }
        return 0
    }

    private static func leadingWorkingDirectoryGuardEndIndex(
        in words: [TerminalStartupWorkingDirectoryPrefix.ShellWordRange]
    ) -> Int? {
        guard let first = words.first?.value else { return nil }
        guard first == "{" || first == "cd" else { return nil }
        return words.firstIndex { $0.value == "&&" }
    }

    private static func isEnvironmentAssignment(_ word: String) -> Bool {
        guard let equals = word.firstIndex(of: "="), equals != word.startIndex else {
            return false
        }
        let name = word[..<equals]
        let allowedFirstScalars = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_"
        )
        let allowedNameScalars = allowedFirstScalars.union(CharacterSet(charactersIn: "0123456789"))
        guard let first = name.unicodeScalars.first, allowedFirstScalars.contains(first) else { return false }
        return name.unicodeScalars.allSatisfy { allowedNameScalars.contains($0) }
    }

    private static func isEnvironmentAssignmentArgument(
        _ word: TerminalStartupWorkingDirectoryPrefix.ShellWordRange
    ) -> Bool {
        isEnvironmentAssignment(word.value)
    }

    private static func isEnvironmentAssignmentSyntax(
        _ word: TerminalStartupWorkingDirectoryPrefix.ShellWordRange,
        in command: String
    ) -> Bool {
        guard isEnvironmentAssignment(word.value),
              let valueEquals = word.value.firstIndex(of: "=") else {
            return false
        }
        let rawWord = String(command[word.range])
        guard let rawEquals = rawWord.firstIndex(of: "=") else { return false }
        return rawWord[..<rawEquals] == word.value[..<valueEquals]
    }
}
