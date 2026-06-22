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
        guard repairPortableAgentExecutable, isAgentHookBinding else {
            return startupCommand
        }
        return SurfaceResumeCommandCanonicalizer.replacingPortableAgentExecutable(
            in: startupCommand,
            kind: kind
        )
    }
}

extension SurfaceResumeCommandCanonicalizer {
    static func replacingPortableAgentExecutable(in command: String, kind: String?) -> String {
        guard let executableName = portableAgentExecutableName(for: kind) else { return command }
        let words = TerminalStartupWorkingDirectoryPrefix.shellWordRanges(command)
        guard let executableIndex = commandExecutableWordIndex(in: words) else { return command }
        let executable = words[executableIndex].value
        guard executable.hasPrefix("/"),
              (executable as NSString).lastPathComponent == executableName,
              isPATHManagedAgentExecutablePath(executable, executableName: executableName) else {
            return command
        }
        guard !isExecutableFile(atPath: executable) else {
            return command
        }

        if executableName == "claude" {
            return replacingStaleClaudeExecutable(
                in: command,
                words: words,
                executableIndex: executableIndex
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

    private static func replacingStaleClaudeExecutable(
        in command: String,
        words: [TerminalStartupWorkingDirectoryPrefix.ShellWordRange],
        executableIndex: Int
    ) -> String {
        let commandStartIndex = commandStartWordIndex(in: words)
        guard commandStartIndex < words.count,
              executableIndex >= commandStartIndex else {
            return command
        }
        var parts = Array(words[commandStartIndex...].map(\.value))
        guard !containsShellControlSyntax(parts) else {
            return command
        }
        guard canRenderStaleClaudeCommandAsPortableArgv(
            words: words,
            commandStartIndex: commandStartIndex,
            executableIndex: executableIndex
        ) else {
            return replacingExecutableOnly(
                in: command,
                words: words,
                executableIndex: executableIndex,
                executableName: "claude"
            )
        }
        parts[executableIndex - commandStartIndex] = "claude"
        let renderedCommand = AgentResumeArgv.renderedPortableClaudeResumeShellCommand(
            parts: parts,
            quote: shellQuoted
        )
        let commandStart = words[commandStartIndex].range.lowerBound
        return String(command[..<commandStart]) + renderedCommand
    }

    private static func canRenderStaleClaudeCommandAsPortableArgv(
        words: [TerminalStartupWorkingDirectoryPrefix.ShellWordRange],
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
            isEnvironmentAssignment($0.value)
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

    private static func containsShellControlSyntax(_ parts: [String]) -> Bool {
        parts.contains { part in
            part == "&&"
                || part == "||"
                || part == ";"
                || part == "|"
                || part == "&"
                || part.hasPrefix(">")
                || part.hasPrefix("<")
                || part.hasPrefix("2>")
        }
    }

    private static func commandExecutableWordIndex(
        in words: [TerminalStartupWorkingDirectoryPrefix.ShellWordRange]
    ) -> Int? {
        var index = commandStartWordIndex(in: words)
        guard index < words.count else { return nil }
        while index < words.count, isEnvironmentAssignment(words[index].value) {
            index += 1
        }
        guard index < words.count else { return nil }
        if words[index].value == "env" || words[index].value == "/usr/bin/env" {
            index += 1
            while index < words.count, isEnvironmentAssignment(words[index].value) {
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
}
