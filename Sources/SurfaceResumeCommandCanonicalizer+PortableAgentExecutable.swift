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
        source: String?
    ) -> String {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard source == "agent-hook" else { return trimmed }
        return TerminalStartupWorkingDirectoryPrefix.replacingRequiredChangeDirectoryPrefix(
            in: trimmed,
            workingDirectory: cwd
        )
    }

    func inlineStartupInput(repairPortableAgentExecutable: Bool) -> String? {
        let trimmed = resolvedStartupCommand(
            repairPortableAgentExecutable: repairPortableAgentExecutable
        ).trimmingCharacters(in: .whitespacesAndNewlines)
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

    func startupInputWithLauncherScript(
        fileManager: FileManager = .default,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        allowLauncherScript: Bool = true,
        repairPortableAgentExecutable: Bool
    ) -> String? {
        guard let inlineInput = inlineStartupInput(
            repairPortableAgentExecutable: repairPortableAgentExecutable
        ) else { return nil }
        guard inlineInput.utf8.count > Self.maxInlineStartupInputBytes else {
            return inlineInput
        }
        guard allowLauncherScript else { return inlineInput }
        guard let scriptURL = SurfaceResumeBindingScriptStore.writeLauncherScript(
            inlineInput: inlineInput,
            binding: self,
            fileManager: fileManager,
            temporaryDirectory: temporaryDirectory
        ) else {
            return nil
        }

        let scriptInput = "/bin/zsh \(Self.shellSingleQuoted(scriptURL.path))\n"
        return scriptInput.utf8.count <= Self.maxInlineStartupInputBytes ? scriptInput : nil
    }

    func remoteStartupInputWithLauncherScript(allowLauncherScript: Bool = false) -> String? {
        startupInputWithLauncherScript(
            allowLauncherScript: allowLauncherScript,
            repairPortableAgentExecutable: false
        )
    }

    func startupCommandWithLauncherScript(
        fileManager: FileManager = .default,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        repairPortableAgentExecutable: Bool
    ) -> String? {
        guard let inlineInput = inlineStartupInput(repairPortableAgentExecutable: repairPortableAgentExecutable),
              let scriptURL = SurfaceResumeBindingScriptStore.writeLauncherScript(
                  inlineInput: inlineInput,
                  binding: self,
                  fileManager: fileManager,
                  temporaryDirectory: temporaryDirectory,
                  returnToLoginShell: true
              ) else {
            return nil
        }
        return "/bin/zsh \(Self.shellSingleQuoted(scriptURL.path))"
    }

    private func resolvedStartupCommand(repairPortableAgentExecutable: Bool) -> String {
        let command = if repairPortableAgentExecutable, isAgentHookBinding {
            SurfaceResumeCommandCanonicalizer.replacingPortableAgentExecutable(
                in: startupCommand,
                kind: kind
            )
        } else {
            startupCommand
        }
        // Only wrap local startup paths in the `/bin/zsh -lc` retry launcher. `repairPortableAgentExecutable`
        // is set exactly for the local agent-hook dispatch (where cmux repairs the executable to its wrapper
        // shim and `/bin/zsh` is guaranteed); the remote path passes `false`, and remote hosts may not have
        // `/bin/zsh`, so forcing the retry launcher there would break Codex resume for those hosts.
        guard repairPortableAgentExecutable,
              isAgentHookBinding,
              kind?.trimmingCharacters(in: .whitespacesAndNewlines) == "codex" else {
            return command
        }
        let commandWithoutCwdPrefix = TerminalStartupWorkingDirectoryPrefix.replacingRequiredChangeDirectoryPrefix(
            in: command,
            previousWorkingDirectory: cwd,
            workingDirectory: nil
        )
        let wrappedCommand = CodexResumeRetryShell().wrappedCommand(
            commandWithoutCwdPrefix,
            quote: Self.shellSingleQuoted
        )
        return TerminalStartupWorkingDirectoryPrefix.prefix(wrappedCommand, workingDirectory: cwd)
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
        guard !isExecutableFile(atPath: executable) else {
            return command
        }

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
            // Mirror claude: route a stale codex executable (a PATH-managed path
            // whose file is gone) through the codex wrapper token instead of a
            // bare `codex`, so the restored codex surface keeps cmux hooks.
            // https://github.com/manaflow-ai/cmux/issues/5639
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
        case "claude":
            return "claude"
        case "codex":
            return "codex"
        default:
            return nil
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
            return replacingStaleExecutableWithWrapperShellCommand(
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
            return replacingStaleExecutableWithWrapperShellCommand(
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

    private static func replacingStaleExecutableWithWrapperShellCommand(
        in command: String,
        words: [TerminalStartupWorkingDirectoryPrefix.ShellWordRange],
        commandStartIndex: Int,
        executableIndex: Int,
        wrapperToken: String,
        wrapInPortableShell: (String) -> String
    ) -> String {
        let renderedParts = words[commandStartIndex...].indices.map { index in
            if index == executableIndex {
                return wrapperToken
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

    private static func commandExecutableWordIndex(
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

    private static func commandStartWordIndex(
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
