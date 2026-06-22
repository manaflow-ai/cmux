import Foundation

extension SurfaceResumeBindingSnapshot {
    var startupCommand: String {
        command
    }

    static func sanitizedStartupCommand(
        _ command: String,
        cwd: String?,
        kind: String?,
        source: String?
    ) -> String {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard source == "agent-hook" else { return trimmed }
        let canonicalCommand = TerminalStartupWorkingDirectoryPrefix.replacingRequiredChangeDirectoryPrefix(
            in: trimmed,
            workingDirectory: cwd
        )
        return SurfaceResumeCommandCanonicalizer.replacingMissingPortableAgentExecutable(
            in: canonicalCommand,
            kind: kind
        )
    }
}

extension SurfaceResumeCommandCanonicalizer {
    static func replacingMissingPortableAgentExecutable(
        in command: String,
        kind: String?,
        fileManager: FileManager = .default
    ) -> String {
        guard let executableName = portableAgentExecutableName(for: kind) else { return command }
        let words = TerminalStartupWorkingDirectoryPrefix.shellWordRanges(command)
        guard let executableIndex = commandExecutableWordIndex(in: words) else { return command }
        let executable = words[executableIndex].value
        guard executable.hasPrefix("/"),
              (executable as NSString).lastPathComponent == executableName,
              !fileManager.fileExists(atPath: executable) else {
            return command
        }

        var repaired = command
        repaired.replaceSubrange(words[executableIndex].range, with: shellQuoted(executableName))
        return repaired
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

    private static func commandExecutableWordIndex(
        in words: [TerminalStartupWorkingDirectoryPrefix.ShellWordRange]
    ) -> Int? {
        var index = 0
        if let guardEndIndex = leadingWorkingDirectoryGuardEndIndex(in: words) {
            index = guardEndIndex + 1
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
