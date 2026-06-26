import Foundation

struct WorkspaceHermesAgentCommandBootstrapper {
    private let hermesCodexEnvironment: WorkspaceHermesCodexEnvironment

    init(hermesCodexEnvironment: WorkspaceHermesCodexEnvironment) {
        self.hermesCodexEnvironment = hermesCodexEnvironment
    }

    func bindingForStartup<Binding: WorkspaceSurfaceResumeBinding>(_ binding: Binding) -> Binding {
        guard binding.source == "agent-hook",
              binding.kind == "hermes-agent" else {
            return binding
        }

        var environment = binding.environment ?? [:]
        environment = hermesCodexEnvironment.applyDefaultCodexBaseURL(to: environment)
        guard let baseURL = normalizedSurfaceResumeValue(
            environment[hermesCodexEnvironment.customBaseURLEnvironmentKey]
        ) else {
            return binding
        }
        environment[hermesCodexEnvironment.customBaseURLEnvironmentKey] = baseURL

        var result = binding
        result.environment = environment.isEmpty ? nil : environment
        result.command = commandByPreparingHermesStartup(
            result.command,
            baseURL: baseURL,
            environment: environment
        )
        return result
    }

    private func commandByPreparingHermesStartup(
        _ command: String,
        baseURL: String,
        environment: [String: String]
    ) -> String {
        if let portableCommand = portableShellCommand(command) {
            let innerCommand = commandByPreparingPlainHermesStartup(
                portableCommand.innerCommand,
                baseURL: baseURL,
                environment: environment
            )
            var result = command
            result.replaceSubrange(portableCommand.innerCommandRange, with: shellQuote(innerCommand))
            return result
        }
        return commandByPreparingPlainHermesStartup(command, baseURL: baseURL, environment: environment)
    }

    private func commandByPreparingPlainHermesStartup(
        _ command: String,
        baseURL: String,
        environment: [String: String]
    ) -> String {
        var result = commandByReplacingOpenAICodexProvider(command)
        result = commandByRemovingBootstrapPrefix(result)
        let agentCommandWords = wordsAfterCwdGuard(shellWords(in: result))
        guard !commandSetsModelAPIMode(agentCommandWords),
              commandAllowsCodexBootstrap(agentCommandWords) else {
            return result
        }
        let hermesExecutable = commandExecutable(agentCommandWords)

        var bootstrap = [
            "\(shellQuote(hermesExecutable)) config set model.provider \(shellQuote(hermesCodexEnvironment.defaultProvider)) >/dev/null",
            "\(shellQuote(hermesExecutable)) config set model.base_url \(shellQuote(baseURL)) >/dev/null",
            "\(shellQuote(hermesExecutable)) config set model.api_mode \(shellQuote(hermesCodexEnvironment.codexResponsesAPIMode)) >/dev/null"
        ]
        if let model = hermesCodexEnvironment.defaultCodexModel(environment: environment) {
            bootstrap.append(
                "\(shellQuote(hermesExecutable)) config set model.default \(shellQuote(model)) >/dev/null"
            )
        }
        result = commandByInsertingBootstrap(bootstrap, into: result)
        return result
    }

    func restorableTmuxStartCommand(_ rawCommand: String?) -> String? {
        guard let command = rawCommand?.trimmingCharacters(in: .whitespacesAndNewlines),
              !command.isEmpty,
              terminalCommandLooksLikeOMXHud(command) else {
            return nil
        }
        return command
    }

    private func commandByInsertingBootstrap(
        _ bootstrap: [String],
        into command: String
    ) -> String {
        let bootstrapCommand = bootstrap.joined(separator: " && ") + " && "
        let words = shellWords(in: command)
        let commandStart = commandStartIndexAfterCwdGuard(words)
        guard commandStart < words.endIndex else {
            return bootstrapCommand + command
        }
        let insertIndex = words[commandStart].range.lowerBound
        return String(command[..<insertIndex]) + bootstrapCommand + String(command[insertIndex...])
    }

    private func commandByReplacingOpenAICodexProvider(_ command: String) -> String {
        var result = command
        var replacements: [(Range<String.Index>, String)] = []
        let words = shellWords(in: command)
        for index in words.indices {
            let word = words[index]
            if word.value == "--provider",
               index + 1 < words.count,
               words[index + 1].value == "openai-codex" {
                replacements.append((
                    words[index + 1].range,
                    shellQuote(hermesCodexEnvironment.defaultProvider)
                ))
            } else if word.value == "--provider=openai-codex" {
                replacements.append((
                    word.range,
                    shellQuote("--provider=\(hermesCodexEnvironment.defaultProvider)")
                ))
            }
        }
        for (range, replacement) in replacements.reversed() {
            result.replaceSubrange(range, with: replacement)
        }
        return result
    }

    private func commandByRemovingBootstrapPrefix(_ command: String) -> String {
        let words = shellWords(in: command)
        var scanIndex = commandStartIndexAfterCwdGuard(words)
        guard scanIndex < words.endIndex else { return command }
        let removeStartIndex = scanIndex
        var removedBootstrap = false

        while let endIndex = bootstrapCommandEndIndex(words, startIndex: scanIndex) {
            removedBootstrap = true
            scanIndex = endIndex
            if scanIndex < words.endIndex, words[scanIndex].value == "&&" {
                scanIndex = words.index(after: scanIndex)
                continue
            }
            break
        }

        guard removedBootstrap,
              scanIndex < words.endIndex else {
            return command
        }
        let removeStart = words[removeStartIndex].range.lowerBound
        let removeEnd = words[scanIndex].range.lowerBound
        return String(command[..<removeStart]) + String(command[removeEnd...])
    }

    private func bootstrapCommandEndIndex(
        _ words: [ShellWord],
        startIndex: Int
    ) -> Int? {
        guard startIndex + 4 < words.endIndex,
              commandWordIsExecutable(words[startIndex].value),
              words[startIndex + 1].value == "config",
              words[startIndex + 2].value == "set",
              bootstrapConfigKeys.contains(words[startIndex + 3].value) else {
            return nil
        }
        var endIndex = startIndex + 5
        if endIndex < words.endIndex, words[endIndex].value == ">/dev/null" {
            endIndex = words.index(after: endIndex)
        }
        return endIndex
    }

    private let bootstrapConfigKeys: Set<String> = [
        "model.provider",
        "model.base_url",
        "model.api_mode",
        "model.default",
    ]

    private func commandSetsModelAPIMode(_ words: [ShellWord]) -> Bool {
        words.contains { $0.value.contains("model.api_mode") }
    }

    private func commandAllowsCodexBootstrap(_ words: [ShellWord]) -> Bool {
        guard let provider = providerArgument(words) else {
            return true
        }
        return provider == hermesCodexEnvironment.defaultProvider || provider == "openai-codex"
    }

    private func providerArgument(_ words: [ShellWord]) -> String? {
        var index = 0
        while index < words.count {
            let word = words[index].value
            if word == "--provider", index + 1 < words.count {
                return words[index + 1].value
            }
            if word.hasPrefix("--provider=") {
                return String(word.dropFirst("--provider=".count))
            }
            index += 1
        }
        return nil
    }

    private func commandExecutable(_ words: [ShellWord]) -> String {
        for word in words {
            guard word.value != "env",
                  !isShellAssignment(word.value) else {
                continue
            }
            if commandWordIsExecutable(word.value) {
                return word.value
            }
        }
        return "hermes"
    }

    private func commandWordIsExecutable(_ value: String) -> Bool {
        let basename = (value as NSString).lastPathComponent
        return basename == "hermes" || basename == "hermes-agent"
    }

    private func wordsAfterCwdGuard(_ words: [ShellWord]) -> [ShellWord] {
        let commandStart = commandStartIndexAfterCwdGuard(words)
        guard commandStart < words.endIndex else { return [] }
        return Array(words[commandStart...])
    }

    private func commandStartIndexAfterCwdGuard(_ words: [ShellWord]) -> Int {
        guard let first = words.first,
              first.value == "{" || first.value == "cd" else {
            return words.startIndex
        }
        guard let andIndex = words.firstIndex(where: { $0.value == "&&" }) else {
            return words.startIndex
        }
        return words.index(after: andIndex)
    }

    private func isShellAssignment(_ value: String) -> Bool {
        guard let equalIndex = value.firstIndex(of: "="),
              equalIndex > value.startIndex else {
            return false
        }
        let key = value[..<equalIndex]
        guard let first = key.first,
              first == "_" || first.isLetter else {
            return false
        }
        return key.allSatisfy { $0 == "_" || $0.isLetter || $0.isNumber }
    }

    private struct ShellWord {
        let value: String
        let range: Range<String.Index>
    }

    private func portableShellCommand(_ command: String) -> (innerCommand: String, innerCommandRange: Range<String.Index>)? {
        let words = shellWords(in: command)
        let commandStartIndex = commandStartIndexAfterCwdGuard(words)
        guard commandStartIndex + 2 < words.count,
              words.count == commandStartIndex + 3,
              words[commandStartIndex].value == "/bin/sh",
              words[commandStartIndex + 1].value == "-c" || words[commandStartIndex + 1].value == "-lc" else {
            return nil
        }
        return (
            innerCommand: words[commandStartIndex + 2].value,
            innerCommandRange: words[commandStartIndex + 2].range
        )
    }

    private func shellWords(in command: String) -> [ShellWord] {
        var words: [ShellWord] = []
        var index = command.startIndex
        while index < command.endIndex {
            while index < command.endIndex, command[index].isWhitespace {
                index = command.index(after: index)
            }
            guard index < command.endIndex else { break }

            let start = index
            var value = ""
            var isComplete = true
            while index < command.endIndex, !command[index].isWhitespace {
                let character = command[index]
                if character == "'" {
                    index = command.index(after: index)
                    var foundEndQuote = false
                    while index < command.endIndex {
                        let quotedCharacter = command[index]
                        if quotedCharacter == "'" {
                            index = command.index(after: index)
                            foundEndQuote = true
                            break
                        }
                        value.append(quotedCharacter)
                        index = command.index(after: index)
                    }
                    if !foundEndQuote {
                        isComplete = false
                        break
                    }
                } else if character == "\"" {
                    index = command.index(after: index)
                    var foundEndQuote = false
                    while index < command.endIndex {
                        let quotedCharacter = command[index]
                        if quotedCharacter == "\"" {
                            index = command.index(after: index)
                            foundEndQuote = true
                            break
                        }
                        if quotedCharacter == "\\" {
                            let next = command.index(after: index)
                            guard next < command.endIndex else {
                                isComplete = false
                                index = command.endIndex
                                break
                            }
                            value.append(command[next])
                            index = command.index(after: next)
                            continue
                        }
                        value.append(quotedCharacter)
                        index = command.index(after: index)
                    }
                    if !foundEndQuote || !isComplete {
                        isComplete = false
                        break
                    }
                } else if character == "\\" {
                    let next = command.index(after: index)
                    guard next < command.endIndex else {
                        isComplete = false
                        index = command.endIndex
                        break
                    }
                    value.append(command[next])
                    index = command.index(after: next)
                } else {
                    value.append(character)
                    index = command.index(after: index)
                }
            }
            if isComplete, !value.isEmpty {
                words.append(ShellWord(value: value, range: start..<index))
            }
        }
        return words
    }

    private func normalizedSurfaceResumeValue(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func terminalCommandLooksLikeOMXHud(_ command: String) -> Bool {
        let lowered = command.lowercased()
        guard terminalCommandTextContainsWord(lowered, word: "hud") else {
            return false
        }
        return lowered.contains("omx") || lowered.contains("oh-my-codex")
    }

    private func terminalCommandTextContainsWord(_ command: String, word: String) -> Bool {
        let escapedWord = NSRegularExpression.escapedPattern(for: word)
        let pattern = "(^|[^A-Za-z0-9_-])\(escapedWord)([^A-Za-z0-9_-]|$)"
        return command.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }
}
