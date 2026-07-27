import CMUXAgentLaunch
import Foundation

extension SurfaceResumeCommandCanonicalizer {
    /// Inserts codex's per-invocation update-check suppression override into a
    /// persisted codex resume binding command that predates the override.
    ///
    /// Agent-hook resume bindings are persisted as rendered shell strings, so a
    /// binding saved by a cmux build without the override replays verbatim on
    /// the first relaunch after updating cmux — exactly the restart where
    /// codex's blocking "Update available!" startup picker used to swallow the
    /// restored session. Normalizing at replay time (not persistence) upgrades
    /// stale bindings without a migration. The override is inserted directly
    /// after the parsed `resume <session-id>` words; commands that already set
    /// `check_for_update_on_startup` through a parsed codex config flag (either
    /// value) and shapes that don't parse to a codex resume argv are returned
    /// unchanged.
    static func insertingCodexUpdateCheckSuppression(
        in command: String,
        kind: String?
    ) -> String {
        let normalizedKind = kind?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedKind == nil || normalizedKind == "codex" else {
            return command
        }
        let words = TerminalStartupWorkingDirectoryPrefix.shellWordRanges(command)
        guard let executableIndex = commandExecutableWordIndex(in: words, command: command) else {
            return command
        }
        if let updated = insertingCodexUpdateCheckSuppression(
            in: command,
            words: words,
            executableIndex: executableIndex,
            normalizedKind: normalizedKind
        ) {
            return updated
        }
        if let updated = insertingCodexUpdateCheckSuppressionIntoShellWrapper(
            in: command,
            words: words,
            executableIndex: executableIndex,
            normalizedKind: normalizedKind
        ) {
            return updated
        }
        return command
    }

    private static func insertingCodexUpdateCheckSuppression(
        in command: String,
        words: [TerminalStartupWorkingDirectoryPrefix.ShellWordRange],
        executableIndex: Int,
        normalizedKind: String?
    ) -> String? {
        let executable = words[executableIndex].value
        let executableBasename = (executable as NSString).lastPathComponent
        let commandWordIndex = executableIndex + 1
        let isCodexExecutable = executableBasename == "codex"
        let isCodexTeamsCommand = commandWordIndex < words.count && words[commandWordIndex].value == "codex-teams"
        guard normalizedKind == "codex" || isCodexExecutable || isCodexTeamsCommand else {
            return nil
        }

        let resumeIndex = isCodexTeamsCommand ? commandWordIndex + 1 : commandWordIndex
        let sessionIndex = resumeIndex + 1
        guard sessionIndex < words.count,
              words[resumeIndex].value == "resume" else {
            return nil
        }
        let parsedArguments = words[(executableIndex + 1)...].map(\.value)
        guard !codexResumeConfigOverrideAlreadyPresent(in: parsedArguments) else {
            return nil
        }
        if words[sessionIndex].value == "--remote" {
            let threadIndex = resumeIndex + 3
            guard threadIndex < words.count,
                  !words[threadIndex].value.hasPrefix("-") else {
                return nil
            }
            return insertingOverride(in: command, after: words[threadIndex])
        }
        guard !words[sessionIndex].value.hasPrefix("-") else {
            return nil
        }
        return insertingOverride(in: command, after: words[sessionIndex])
    }

    private static func insertingOverride(
        in command: String,
        after word: TerminalStartupWorkingDirectoryPrefix.ShellWordRange
    ) -> String {
        let overrideText = AgentResumeArgv.codexUpdateCheckSuppressionOverride
            .map(shellQuoted)
            .joined(separator: " ")
        var updated = command
        updated.insert(contentsOf: " " + overrideText, at: word.range.upperBound)
        return updated
    }

    private static func insertingCodexUpdateCheckSuppressionIntoShellWrapper(
        in command: String,
        words: [TerminalStartupWorkingDirectoryPrefix.ShellWordRange],
        executableIndex: Int,
        normalizedKind: String?
    ) -> String? {
        let executableBasename = (words[executableIndex].value as NSString).lastPathComponent
        guard executableBasename == "sh" || executableBasename == "zsh" || executableBasename == "bash" else {
            return nil
        }
        let optionIndex = executableIndex + 1
        let commandIndex = executableIndex + 2
        guard commandIndex < words.count,
              words[optionIndex].value == "-c" || words[optionIndex].value == "-lc" else {
            return nil
        }
        let innerCommand = words[commandIndex].value
        guard let updatedInner = insertingCodexUpdateCheckSuppressionInShellWrapperBody(
            innerCommand,
            normalizedKind: normalizedKind
        ), updatedInner != innerCommand else {
            return nil
        }
        var updated = command
        updated.replaceSubrange(words[commandIndex].range, with: shellQuoted(updatedInner))
        return updated
    }

    private static func insertingCodexUpdateCheckSuppressionInShellWrapperBody(
        _ command: String,
        normalizedKind: String?
    ) -> String? {
        let words = TerminalStartupWorkingDirectoryPrefix.shellWordRanges(command)
        if let executableIndex = commandExecutableWordIndex(in: words, command: command),
           let updated = insertingCodexUpdateCheckSuppression(
            in: command,
            words: words,
            executableIndex: executableIndex,
            normalizedKind: normalizedKind
           ) {
            return updated
        }
        let wrapperToken = AgentResumeArgv.codexWrapperShellExecutableToken
        guard command.hasPrefix(wrapperToken) else {
            return nil
        }
        let tailStart = command.index(command.startIndex, offsetBy: wrapperToken.count)
        let tail = String(command[tailStart...])
        let tailWords = TerminalStartupWorkingDirectoryPrefix.shellWordRanges(tail)
        let resumeIndex = 0
        let sessionIndex = 1
        guard sessionIndex < tailWords.count,
              tailWords[resumeIndex].value == "resume" else {
            return nil
        }
        guard !codexResumeConfigOverrideAlreadyPresent(in: tailWords.map(\.value)) else {
            return nil
        }
        let insertionWord: TerminalStartupWorkingDirectoryPrefix.ShellWordRange
        if tailWords[sessionIndex].value == "--remote" {
            let threadIndex = resumeIndex + 3
            guard threadIndex < tailWords.count,
                  !tailWords[threadIndex].value.hasPrefix("-") else {
                return nil
            }
            insertionWord = tailWords[threadIndex]
        } else {
            guard !tailWords[sessionIndex].value.hasPrefix("-") else {
                return nil
            }
            insertionWord = tailWords[sessionIndex]
        }
        let overrideText = AgentResumeArgv.codexUpdateCheckSuppressionOverride
            .map(shellQuoted)
            .joined(separator: " ")
        let insertionOffset = tail.distance(
            from: tail.startIndex,
            to: insertionWord.range.upperBound
        )
        let insertionIndex = command.index(tailStart, offsetBy: insertionOffset)
        var updated = command
        updated.insert(contentsOf: " " + overrideText, at: insertionIndex)
        return updated
    }

    static func codexResumeSessionId(in command: String, kind: String?) -> String? {
        codexResumeSessionId(
            in: command,
            normalizedKind: kind?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            depth: 0
        )
    }

    static func replacingCodexResumeSession(
        in command: String,
        kind: String?,
        expectedSessionId: String,
        replacementSessionId: String
    ) -> String? {
        replacingCodexResumeSession(
            in: command,
            normalizedKind: kind?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            expectedSessionId: expectedSessionId,
            replacementSessionId: replacementSessionId,
            depth: 0
        )
    }

    private static func codexResumeSessionId(
        in command: String,
        normalizedKind: String?,
        depth: Int
    ) -> String? {
        guard depth < 4 else { return nil }
        let words = TerminalStartupWorkingDirectoryPrefix.shellWordRanges(command)
        guard let executableIndex = commandExecutableWordIndex(in: words, command: command) else {
            return nil
        }
        if let sessionWord = codexResumeSessionWord(
            in: words,
            executableIndex: executableIndex,
            normalizedKind: normalizedKind
        ) {
            return sessionWord.value
        }
        guard let commandWord = shellWrapperCommandWord(
            in: words,
            executableIndex: executableIndex
        ) else {
            return nil
        }
        return codexResumeSessionId(
            in: commandWord.value,
            normalizedKind: normalizedKind,
            depth: depth + 1
        )
    }

    private static func replacingCodexResumeSession(
        in command: String,
        normalizedKind: String?,
        expectedSessionId: String,
        replacementSessionId: String,
        depth: Int
    ) -> String? {
        guard depth < 4 else { return nil }
        let words = TerminalStartupWorkingDirectoryPrefix.shellWordRanges(command)
        guard let executableIndex = commandExecutableWordIndex(in: words, command: command) else {
            return nil
        }
        if let sessionWord = codexResumeSessionWord(
            in: words,
            executableIndex: executableIndex,
            normalizedKind: normalizedKind
        ) {
            guard sessionWord.value == expectedSessionId else { return nil }
            var updated = command
            updated.replaceSubrange(sessionWord.range, with: shellQuoted(replacementSessionId))
            return updated
        }
        guard let commandWord = shellWrapperCommandWord(
            in: words,
            executableIndex: executableIndex
        ), let updatedInner = replacingCodexResumeSession(
            in: commandWord.value,
            normalizedKind: normalizedKind,
            expectedSessionId: expectedSessionId,
            replacementSessionId: replacementSessionId,
            depth: depth + 1
        ) else {
            return nil
        }
        var updated = command
        updated.replaceSubrange(commandWord.range, with: shellQuoted(updatedInner))
        return updated
    }

    private static func codexResumeSessionWord(
        in words: [TerminalStartupWorkingDirectoryPrefix.ShellWordRange],
        executableIndex: Int,
        normalizedKind: String?
    ) -> TerminalStartupWorkingDirectoryPrefix.ShellWordRange? {
        let executable = words[executableIndex].value
        let executableBasename = (executable as NSString).lastPathComponent
        let commandWordIndex = executableIndex + 1
        let isCodexTeamsCommand =
            commandWordIndex < words.count && words[commandWordIndex].value == "codex-teams"
        let isCodexWrapper = executable == AgentResumeArgv.codexWrapperShellExecutableToken
        guard normalizedKind == "codex" ||
                executableBasename == "codex" ||
                isCodexTeamsCommand ||
                isCodexWrapper else {
            return nil
        }

        let resumeIndex = isCodexTeamsCommand ? commandWordIndex + 1 : commandWordIndex
        let sessionIndex = resumeIndex + 1
        guard sessionIndex < words.count, words[resumeIndex].value == "resume" else {
            return nil
        }
        if words[sessionIndex].value == "--remote" {
            let threadIndex = resumeIndex + 3
            guard threadIndex < words.count,
                  !words[threadIndex].value.hasPrefix("-") else {
                return nil
            }
            return words[threadIndex]
        }
        guard !words[sessionIndex].value.hasPrefix("-") else { return nil }
        return words[sessionIndex]
    }

    private static func shellWrapperCommandWord(
        in words: [TerminalStartupWorkingDirectoryPrefix.ShellWordRange],
        executableIndex: Int
    ) -> TerminalStartupWorkingDirectoryPrefix.ShellWordRange? {
        let executableBasename = (words[executableIndex].value as NSString).lastPathComponent
        guard executableBasename == "sh" ||
                executableBasename == "zsh" ||
                executableBasename == "bash" else {
            return nil
        }
        let optionIndex = executableIndex + 1
        let commandIndex = executableIndex + 2
        guard commandIndex < words.count,
              words[optionIndex].value == "-c" || words[optionIndex].value == "-lc" else {
            return nil
        }
        return words[commandIndex]
    }

    private static func codexResumeConfigOverrideAlreadyPresent(in arguments: [String]) -> Bool {
        AgentResumeArgv().hasExplicitCheckForUpdateOnStartupOverride(in: arguments)
    }
}
