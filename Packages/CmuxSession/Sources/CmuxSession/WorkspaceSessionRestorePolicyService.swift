public import Foundation

/// Service that owns workspace session restore policy decisions.
///
/// The app target injects concrete approval storage, prompt handling, automated
/// test detection, scrollback truncation, and Hermes Codex defaults. That keeps
/// this package independent of app DTO storage and UI while preserving the
/// exact restore behavior.
public struct WorkspaceSessionRestorePolicyService<Binding: WorkspaceSurfaceResumeBinding>: Sendable {
    private let applyStoredApproval: @Sendable (Binding, URL, Data?) -> Binding
    private let shouldRunPromptedSurfaceResume: @Sendable (Binding) -> Bool
    private let isRunningUnderAutomatedTests: @Sendable () -> Bool
    private let truncateScrollback: @Sendable (String?) -> String?
    private let hermesCodexEnvironment: WorkspaceHermesCodexEnvironment
    // Justification: FileManager is documented thread-safe but is not marked Sendable.
    private nonisolated(unsafe) let fileManager: FileManager
    private let temporaryDirectory: URL

    /// Creates a restore policy service.
    public init(
        applyStoredApproval: @escaping @Sendable (Binding, URL, Data?) -> Binding,
        shouldRunPromptedSurfaceResume: @escaping @Sendable (Binding) -> Bool,
        isRunningUnderAutomatedTests: @escaping @Sendable () -> Bool,
        truncateScrollback: @escaping @Sendable (String?) -> String?,
        hermesCodexEnvironment: WorkspaceHermesCodexEnvironment,
        fileManager: FileManager,
        temporaryDirectory: URL
    ) {
        self.applyStoredApproval = applyStoredApproval
        self.shouldRunPromptedSurfaceResume = shouldRunPromptedSurfaceResume
        self.isRunningUnderAutomatedTests = isRunningUnderAutomatedTests
        self.truncateScrollback = truncateScrollback
        self.hermesCodexEnvironment = hermesCodexEnvironment
        self.fileManager = fileManager
        self.temporaryDirectory = temporaryDirectory
    }

    /// Resolves the scrollback text persisted for a terminal snapshot.
    public func resolvedSnapshotTerminalScrollback(
        capturedScrollback: String?,
        fallbackScrollback: String?,
        allowFallbackScrollback: Bool = true
    ) -> String? {
        if let captured = truncateScrollback(capturedScrollback) {
            return captured
        }
        guard allowFallbackScrollback else { return nil }
        return truncateScrollback(fallbackScrollback)
    }

    /// Returns whether restored scrollback should be replayed for a terminal.
    public func shouldReplaySessionScrollback(
        hasRestorableAgent: Bool,
        tmuxStartCommand: String? = nil,
        hasResumeStartupWork: Bool = false
    ) -> Bool {
        !hasRestorableAgent && restorableTmuxStartCommand(tmuxStartCommand) == nil && !hasResumeStartupWork
    }

    /// Returns whether a restored remote workspace should auto-connect.
    public func shouldAutoConnectRestoredRemote<Snapshot: WorkspaceSessionRemoteRestoreSnapshot>(
        foregroundAuthToken: String?,
        snapshot: Snapshot,
        isRunningUnderAutomatedTests overrideIsRunningUnderAutomatedTests: Bool? = nil
    ) -> Bool {
        let runningUnderTests = overrideIsRunningUnderAutomatedTests ?? isRunningUnderAutomatedTests()
        guard !runningUnderTests else { return false }
        let normalizedForegroundAuthToken = foregroundAuthToken?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedForegroundAuthToken?.isEmpty == false else { return true }
        let hasTerminalThatWillAuthenticateReconnect = snapshot.panels.contains {
            guard let terminal = $0.terminal else { return false }
            if terminal.isRemoteTerminal != false {
                return true
            }
            let remotePTYSessionID = terminal.remotePTYSessionID?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return remotePTYSessionID?.isEmpty == false
        }
        return !hasTerminalThatWillAuthenticateReconnect
    }

    /// Returns startup input for an approved restored surface resume binding.
    public func surfaceResumeStartupInput(
        _ resumeBinding: Binding?,
        autoResumeAgentSessions: Bool,
        allowLauncherScript: Bool = false,
        promptForApproval: Bool = true,
        approvalStoreURL: URL,
        approvalSigningSecret: Data? = nil
    ) -> String? {
        guard let effectiveBinding = approvedSurfaceResumeBinding(
            resumeBinding,
            autoResumeAgentSessions: autoResumeAgentSessions,
            promptForApproval: promptForApproval,
            approvalStoreURL: approvalStoreURL,
            approvalSigningSecret: approvalSigningSecret
        ) else {
            return nil
        }
        return effectiveBinding.startupInputWithLauncherScript(
            fileManager: fileManager,
            temporaryDirectory: temporaryDirectory,
            allowLauncherScript: allowLauncherScript
        )
    }

    /// Returns the command or input launch action for a restored surface resume binding.
    public func surfaceResumeStartupLaunch(
        _ resumeBinding: Binding?,
        autoResumeAgentSessions: Bool,
        allowLauncherScript: Bool = true,
        promptForApproval: Bool = true,
        approvalStoreURL: URL,
        approvalSigningSecret: Data? = nil
    ) -> WorkspaceSurfaceResumeStartupLaunch? {
        guard let effectiveBinding = approvedSurfaceResumeBinding(
            resumeBinding,
            autoResumeAgentSessions: autoResumeAgentSessions,
            promptForApproval: promptForApproval,
            approvalStoreURL: approvalStoreURL,
            approvalSigningSecret: approvalSigningSecret
        ) else {
            return nil
        }
        return surfaceResumeStartupLaunch(
            forApprovedBinding: effectiveBinding,
            allowLauncherScript: allowLauncherScript
        )
    }

    /// Returns the command or input launch action for an already approved binding.
    public func surfaceResumeStartupLaunch(
        forApprovedBinding effectiveBinding: Binding,
        allowLauncherScript: Bool = true
    ) -> WorkspaceSurfaceResumeStartupLaunch? {
        if effectiveBinding.isAgentHookBinding,
           allowLauncherScript,
           let command = effectiveBinding.startupCommandWithLauncherScript(
               fileManager: fileManager,
               temporaryDirectory: temporaryDirectory
           ) {
            return .command(command)
        }
        guard let input = effectiveBinding.startupInputWithLauncherScript(
            fileManager: fileManager,
            temporaryDirectory: temporaryDirectory,
            allowLauncherScript: allowLauncherScript
        ) else {
            return nil
        }
        return .input(input)
    }

    /// Applies stored approval state and returns the binding allowed to run.
    public func approvedSurfaceResumeBinding(
        _ resumeBinding: Binding?,
        autoResumeAgentSessions: Bool,
        promptForApproval: Bool = true,
        approvalStoreURL: URL,
        approvalSigningSecret: Data? = nil
    ) -> Binding? {
        guard let resumeBinding else { return nil }
        var effectiveBinding = applyStoredApproval(resumeBinding, approvalStoreURL, approvalSigningSecret)
        effectiveBinding = hermesAgentSubrouterBindingForStartup(effectiveBinding)
        if effectiveBinding.source == "agent-hook", !autoResumeAgentSessions {
            return nil
        }
        if effectiveBinding.requiresPromptApproval {
            guard promptForApproval else { return nil }
            guard shouldRunPromptedSurfaceResume(effectiveBinding) else { return nil }
            return effectiveBinding
        }
        guard effectiveBinding.allowsAutomaticResume else { return nil }
        return effectiveBinding
    }

    /// Returns a restorable tmux start command when the command launches an OMX HUD.
    public func restorableTmuxStartCommand(_ rawCommand: String?) -> String? {
        guard let command = rawCommand?.trimmingCharacters(in: .whitespacesAndNewlines),
              !command.isEmpty,
              terminalCommandLooksLikeOMXHud(command) else {
            return nil
        }
        return command
    }

    /// Returns whether terminal scrollback should be persisted when closing/restoring.
    public func shouldPersistSessionScrollback(closeConfirmationRequired: Bool) -> Bool {
        !closeConfirmationRequired
    }

    private func hermesAgentSubrouterBindingForStartup(_ binding: Binding) -> Binding {
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
        result.command = hermesAgentCommandByReplacingOpenAICodexProvider(result.command)
        result.command = hermesAgentCommandByRemovingBootstrapPrefix(result.command)
        let agentCommandWords = hermesAgentWordsAfterCwdGuard(surfaceResumeShellWords(in: result.command))
        guard !hermesAgentCommandSetsModelAPIMode(agentCommandWords),
              hermesAgentCommandAllowsCodexBootstrap(agentCommandWords) else {
            return result
        }
        let hermesExecutable = hermesAgentCommandExecutable(agentCommandWords)

        var bootstrap = [
            "\(surfaceResumeShellQuote(hermesExecutable)) config set model.provider \(surfaceResumeShellQuote(hermesCodexEnvironment.defaultProvider)) >/dev/null",
            "\(surfaceResumeShellQuote(hermesExecutable)) config set model.base_url \(surfaceResumeShellQuote(baseURL)) >/dev/null",
            "\(surfaceResumeShellQuote(hermesExecutable)) config set model.api_mode \(surfaceResumeShellQuote(hermesCodexEnvironment.codexResponsesAPIMode)) >/dev/null"
        ]
        if let model = hermesCodexEnvironment.defaultCodexModel(environment: environment) {
            bootstrap.append(
                "\(surfaceResumeShellQuote(hermesExecutable)) config set model.default \(surfaceResumeShellQuote(model)) >/dev/null"
            )
        }
        result.command = hermesAgentCommandByInsertingBootstrap(bootstrap, into: result.command)
        return result
    }

    private func hermesAgentCommandByInsertingBootstrap(
        _ bootstrap: [String],
        into command: String
    ) -> String {
        let bootstrapCommand = bootstrap.joined(separator: " && ") + " && "
        let words = surfaceResumeShellWords(in: command)
        let commandStart = hermesAgentCommandStartIndexAfterCwdGuard(words)
        guard commandStart < words.endIndex else {
            return bootstrapCommand + command
        }
        let insertIndex = words[commandStart].range.lowerBound
        return String(command[..<insertIndex]) + bootstrapCommand + String(command[insertIndex...])
    }

    private func hermesAgentCommandByReplacingOpenAICodexProvider(_ command: String) -> String {
        var result = command
        var replacements: [(Range<String.Index>, String)] = []
        let words = surfaceResumeShellWords(in: command)
        for index in words.indices {
            let word = words[index]
            if word.value == "--provider",
               index + 1 < words.count,
               words[index + 1].value == "openai-codex" {
                replacements.append((
                    words[index + 1].range,
                    surfaceResumeShellQuote(hermesCodexEnvironment.defaultProvider)
                ))
            } else if word.value == "--provider=openai-codex" {
                replacements.append((
                    word.range,
                    surfaceResumeShellQuote("--provider=\(hermesCodexEnvironment.defaultProvider)")
                ))
            }
        }
        for (range, replacement) in replacements.reversed() {
            result.replaceSubrange(range, with: replacement)
        }
        return result
    }

    private func hermesAgentCommandByRemovingBootstrapPrefix(_ command: String) -> String {
        let words = surfaceResumeShellWords(in: command)
        var scanIndex = hermesAgentCommandStartIndexAfterCwdGuard(words)
        guard scanIndex < words.endIndex else { return command }
        let removeStartIndex = scanIndex
        var removedBootstrap = false

        while let endIndex = hermesAgentBootstrapCommandEndIndex(words, startIndex: scanIndex) {
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

    private func hermesAgentBootstrapCommandEndIndex(
        _ words: [SurfaceResumeShellWord],
        startIndex: Int
    ) -> Int? {
        guard startIndex + 4 < words.endIndex,
              hermesAgentCommandWordIsExecutable(words[startIndex].value),
              words[startIndex + 1].value == "config",
              words[startIndex + 2].value == "set",
              hermesAgentBootstrapConfigKeys.contains(words[startIndex + 3].value) else {
            return nil
        }
        var endIndex = startIndex + 5
        if endIndex < words.endIndex, words[endIndex].value == ">/dev/null" {
            endIndex = words.index(after: endIndex)
        }
        return endIndex
    }

    private let hermesAgentBootstrapConfigKeys: Set<String> = [
        "model.provider",
        "model.base_url",
        "model.api_mode",
        "model.default",
    ]

    private func hermesAgentCommandSetsModelAPIMode(_ words: [SurfaceResumeShellWord]) -> Bool {
        words.contains { $0.value.contains("model.api_mode") }
    }

    private func hermesAgentCommandAllowsCodexBootstrap(
        _ words: [SurfaceResumeShellWord]
    ) -> Bool {
        guard let provider = hermesAgentProviderArgument(words) else {
            return true
        }
        return provider == hermesCodexEnvironment.defaultProvider || provider == "openai-codex"
    }

    private func hermesAgentProviderArgument(_ words: [SurfaceResumeShellWord]) -> String? {
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

    private func hermesAgentCommandExecutable(_ words: [SurfaceResumeShellWord]) -> String {
        for word in words {
            guard word.value != "env",
                  !isSurfaceResumeShellAssignment(word.value) else {
                continue
            }
            if hermesAgentCommandWordIsExecutable(word.value) {
                return word.value
            }
        }
        return "hermes"
    }

    private func hermesAgentCommandWordIsExecutable(_ value: String) -> Bool {
        let basename = (value as NSString).lastPathComponent
        return basename == "hermes" || basename == "hermes-agent"
    }

    private func hermesAgentWordsAfterCwdGuard(
        _ words: [SurfaceResumeShellWord]
    ) -> [SurfaceResumeShellWord] {
        let commandStart = hermesAgentCommandStartIndexAfterCwdGuard(words)
        guard commandStart < words.endIndex else { return [] }
        return Array(words[commandStart...])
    }

    private func hermesAgentCommandStartIndexAfterCwdGuard(
        _ words: [SurfaceResumeShellWord]
    ) -> Int {
        guard let first = words.first,
              first.value == "{" || first.value == "cd" else {
            return words.startIndex
        }
        guard let andIndex = words.firstIndex(where: { $0.value == "&&" }) else {
            return words.startIndex
        }
        return words.index(after: andIndex)
    }

    private func isSurfaceResumeShellAssignment(_ value: String) -> Bool {
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

    private struct SurfaceResumeShellWord {
        let value: String
        let range: Range<String.Index>
    }

    private func surfaceResumeShellWords(in command: String) -> [SurfaceResumeShellWord] {
        var words: [SurfaceResumeShellWord] = []
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
                words.append(SurfaceResumeShellWord(value: value, range: start..<index))
            }
        }
        return words
    }

    private func normalizedSurfaceResumeValue(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    private func surfaceResumeShellQuote(_ value: String) -> String {
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
