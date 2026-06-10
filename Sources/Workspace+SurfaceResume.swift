import Foundation
import SwiftUI
import AppKit
import Bonsplit
import CMUXAgentLaunch
import CmuxSocketControl
import Combine
import CryptoKit
import Darwin
import Network
import CoreText


// MARK: - Surface resume startup and scrollback policies
extension Workspace {
    nonisolated static func resolvedSnapshotTerminalScrollback(
        capturedScrollback: String?,
        fallbackScrollback: String?,
        allowFallbackScrollback: Bool = true
    ) -> String? {
        if let captured = SessionPersistencePolicy.truncatedScrollback(capturedScrollback) {
            return captured
        }
        guard allowFallbackScrollback else { return nil }
        return SessionPersistencePolicy.truncatedScrollback(fallbackScrollback)
    }

    nonisolated static func shouldReplaySessionScrollback(
        restorableAgent: SessionRestorableAgentSnapshot?,
        tmuxStartCommand: String? = nil,
        hasResumeStartupWork: Bool = false
    ) -> Bool {
        // Agent restores relaunch from the provider's session ID. Replaying the
        // old TUI scrollback can print stale launch commands and race resume startup work.
        // OMX HUD panes restore from their tmux start command for the same reason.
        restorableAgent == nil && restorableTmuxStartCommand(tmuxStartCommand) == nil && !hasResumeStartupWork
    }

    nonisolated static func shouldAutoConnectRestoredRemote(
        foregroundAuthToken: String?,
        snapshot: SessionWorkspaceSnapshot,
        isRunningUnderAutomatedTests: Bool = SessionRestorePolicy.isRunningUnderAutomatedTests()
    ) -> Bool {
        guard !isRunningUnderAutomatedTests else { return false }
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

    nonisolated enum SurfaceResumeStartupLaunch {
        case command(String)
        case input(String)

        var initialCommand: String? {
            if case .command(let command) = self {
                return command
            }
            return nil
        }

        var initialInput: String? {
            if case .input(let input) = self {
                return input
            }
            return nil
        }
    }

    nonisolated static func surfaceResumeStartupInput(
        _ resumeBinding: SurfaceResumeBindingSnapshot?,
        autoResumeAgentSessions: Bool,
        allowLauncherScript: Bool = false,
        promptForApproval: Bool = true,
        approvalStoreURL: URL = SurfaceResumeApprovalStore.defaultURL(),
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
        return effectiveBinding.startupInputWithLauncherScript(allowLauncherScript: allowLauncherScript)
    }

    nonisolated static func surfaceResumeStartupLaunch(
        _ resumeBinding: SurfaceResumeBindingSnapshot?,
        autoResumeAgentSessions: Bool,
        allowLauncherScript: Bool = true,
        promptForApproval: Bool = true,
        approvalStoreURL: URL = SurfaceResumeApprovalStore.defaultURL(),
        approvalSigningSecret: Data? = nil,
        fileManager: FileManager = .default,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) -> SurfaceResumeStartupLaunch? {
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
            allowLauncherScript: allowLauncherScript,
            fileManager: fileManager,
            temporaryDirectory: temporaryDirectory
        )
    }

    nonisolated static func surfaceResumeStartupLaunch(
        forApprovedBinding effectiveBinding: SurfaceResumeBindingSnapshot,
        allowLauncherScript: Bool = true,
        fileManager: FileManager = .default,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) -> SurfaceResumeStartupLaunch? {
        if effectiveBinding.isAgentHookBinding,
           allowLauncherScript,
           let command = effectiveBinding.startupCommandWithLauncherScript(
               fileManager: fileManager,
               temporaryDirectory: temporaryDirectory
           ) {
            return .command(command)
        }
        guard let input = effectiveBinding.startupInputWithLauncherScript(
            allowLauncherScript: allowLauncherScript
        ) else {
            return nil
        }
        return .input(input)
    }

    nonisolated static func approvedSurfaceResumeBinding(
        _ resumeBinding: SurfaceResumeBindingSnapshot?,
        autoResumeAgentSessions: Bool,
        promptForApproval: Bool = true,
        approvalStoreURL: URL = SurfaceResumeApprovalStore.defaultURL(),
        approvalSigningSecret: Data? = nil
    ) -> SurfaceResumeBindingSnapshot? {
        guard let resumeBinding else { return nil }
        var effectiveBinding = SurfaceResumeApprovalStore.applyingStoredApproval(
            to: resumeBinding,
            fileURL: approvalStoreURL,
            signingSecret: approvalSigningSecret
        )
        effectiveBinding = hermesAgentSubrouterBindingForStartup(effectiveBinding)
        if effectiveBinding.source == "agent-hook", !autoResumeAgentSessions {
            return nil
        }
        if effectiveBinding.approvalPolicy == .prompt {
            guard promptForApproval else { return nil }
            guard shouldRunPromptedSurfaceResume(effectiveBinding) else { return nil }
            return effectiveBinding
        }
        guard effectiveBinding.allowsAutomaticResume else { return nil }
        return effectiveBinding
    }

    nonisolated private static func hermesAgentSubrouterBindingForStartup(
        _ binding: SurfaceResumeBindingSnapshot
    ) -> SurfaceResumeBindingSnapshot {
        guard binding.source == "agent-hook",
              binding.kind == "hermes-agent" else {
            return binding
        }

        var environment = binding.environment ?? [:]
        environment = HermesAgentCodexEnvironment.applyingDefaultCodexBaseURL(to: environment)
        guard let baseURL = normalizedSurfaceResumeValue(
            environment[HermesAgentCodexEnvironment.customBaseURLEnvironmentKey]
        ) else {
            return binding
        }
        environment[HermesAgentCodexEnvironment.customBaseURLEnvironmentKey] = baseURL

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
            "\(surfaceResumeShellQuote(hermesExecutable)) config set model.provider \(surfaceResumeShellQuote(HermesAgentCodexEnvironment.defaultProvider)) >/dev/null",
            "\(surfaceResumeShellQuote(hermesExecutable)) config set model.base_url \(surfaceResumeShellQuote(baseURL)) >/dev/null",
            "\(surfaceResumeShellQuote(hermesExecutable)) config set model.api_mode \(surfaceResumeShellQuote(HermesAgentCodexEnvironment.codexResponsesAPIMode)) >/dev/null"
        ]
        if let model = HermesAgentCodexEnvironment.defaultCodexModel(environment: environment) {
            bootstrap.append("\(surfaceResumeShellQuote(hermesExecutable)) config set model.default \(surfaceResumeShellQuote(model)) >/dev/null")
        }
        result.command = hermesAgentCommandByInsertingBootstrap(bootstrap, into: result.command)
        return result
    }

    nonisolated private static func hermesAgentCommandByInsertingBootstrap(
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

    nonisolated private static func hermesAgentCommandByReplacingOpenAICodexProvider(_ command: String) -> String {
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
                    surfaceResumeShellQuote(HermesAgentCodexEnvironment.defaultProvider)
                ))
            } else if word.value == "--provider=openai-codex" {
                replacements.append((
                    word.range,
                    surfaceResumeShellQuote("--provider=\(HermesAgentCodexEnvironment.defaultProvider)")
                ))
            }
        }
        for (range, replacement) in replacements.reversed() {
            result.replaceSubrange(range, with: replacement)
        }
        return result
    }

    nonisolated private static func hermesAgentCommandByRemovingBootstrapPrefix(_ command: String) -> String {
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

    nonisolated private static func hermesAgentBootstrapCommandEndIndex(
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

    nonisolated private static let hermesAgentBootstrapConfigKeys: Set<String> = [
        "model.provider",
        "model.base_url",
        "model.api_mode",
        "model.default",
    ]

    nonisolated private static func hermesAgentCommandSetsModelAPIMode(_ words: [SurfaceResumeShellWord]) -> Bool {
        words.contains { $0.value.contains("model.api_mode") }
    }

    nonisolated private static func hermesAgentCommandAllowsCodexBootstrap(
        _ words: [SurfaceResumeShellWord]
    ) -> Bool {
        guard let provider = hermesAgentProviderArgument(words) else {
            return true
        }
        return provider == HermesAgentCodexEnvironment.defaultProvider || provider == "openai-codex"
    }

    nonisolated private static func hermesAgentProviderArgument(_ words: [SurfaceResumeShellWord]) -> String? {
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

    nonisolated private static func hermesAgentCommandExecutable(_ words: [SurfaceResumeShellWord]) -> String {
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

    nonisolated private static func hermesAgentCommandWordIsExecutable(_ value: String) -> Bool {
        let basename = (value as NSString).lastPathComponent
        return basename == "hermes" || basename == "hermes-agent"
    }

    nonisolated private static func hermesAgentWordsAfterCwdGuard(
        _ words: [SurfaceResumeShellWord]
    ) -> [SurfaceResumeShellWord] {
        let commandStart = hermesAgentCommandStartIndexAfterCwdGuard(words)
        guard commandStart < words.endIndex else { return [] }
        return Array(words[commandStart...])
    }

    nonisolated private static func hermesAgentCommandStartIndexAfterCwdGuard(
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

    nonisolated private static func isSurfaceResumeShellAssignment(_ value: String) -> Bool {
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

    nonisolated private static func surfaceResumeShellWords(in command: String) -> [SurfaceResumeShellWord] {
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

    nonisolated private static func normalizedSurfaceResumeValue(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    nonisolated private static func surfaceResumeShellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    nonisolated private static func shouldRunPromptedSurfaceResume(_ binding: SurfaceResumeBindingSnapshot) -> Bool {
        guard Thread.isMainThread, ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else {
            return false
        }
        return MainActor.assumeIsolated {
            shouldRunPromptedSurfaceResumeOnMain(binding)
        }
    }

    @MainActor
    private static func shouldRunPromptedSurfaceResumeOnMain(_ binding: SurfaceResumeBindingSnapshot) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = String(
            localized: "surfaceResumeApproval.runPrompt.title",
            defaultValue: "Run Resume Command?"
        )
        alert.informativeText = String(
            format: String(
                localized: "surfaceResumeApproval.runPrompt.message",
                defaultValue: "cmux is restoring a terminal with this resume command:\n\n%@\n\nWorking directory: %@"
            ),
            binding.command,
            binding.cwd ?? String(localized: "surfaceResumeApproval.cwd.none", defaultValue: "None")
        )
        alert.addButton(withTitle: String(localized: "surfaceResumeApproval.runPrompt.run", defaultValue: "Run"))
        alert.addButton(withTitle: String(localized: "surfaceResumeApproval.runPrompt.skip", defaultValue: "Skip"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    nonisolated static func restorableTmuxStartCommand(_ rawCommand: String?) -> String? {
        guard let command = rawCommand?.trimmingCharacters(in: .whitespacesAndNewlines),
              !command.isEmpty,
              terminalCommandLooksLikeOMXHud(command) else {
            return nil
        }
        return command
    }

    private nonisolated static func terminalCommandLooksLikeOMXHud(_ command: String) -> Bool {
        let lowered = command.lowercased()
        guard terminalCommandTextContainsWord(lowered, word: "hud") else {
            return false
        }
        return lowered.contains("omx") || lowered.contains("oh-my-codex")
    }

    private nonisolated static func terminalCommandTextContainsWord(_ command: String, word: String) -> Bool {
        let escapedWord = NSRegularExpression.escapedPattern(for: word)
        let pattern = "(^|[^A-Za-z0-9_-])\(escapedWord)([^A-Za-z0-9_-]|$)"
        return command.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    nonisolated static func shouldPersistSessionScrollback(
        shellActivityState: PanelShellActivityState?,
        fallbackNeedsConfirmClose: Bool
    ) -> Bool {
        !resolveCloseConfirmation(
            shellActivityState: shellActivityState,
            fallbackNeedsConfirmClose: fallbackNeedsConfirmClose
        )
    }

    func terminalSnapshotScrollback(
        panelId: UUID,
        capturedScrollback: String?,
        includeScrollback: Bool,
        allowFallbackScrollback: Bool = true
    ) -> String? {
        guard includeScrollback else { return nil }
#if DEBUG
        let debugFallback = debugSessionSnapshotScrollbackFallbackPanelIds.contains(panelId)
            ? debugSessionSnapshotSyntheticScrollbackByPanelId[panelId]
            : nil
#else
        let debugFallback: String? = nil
#endif
        let fallback = allowFallbackScrollback
            ? (debugFallback ?? restoredTerminalScrollbackByPanelId[panelId])
            : nil
        let resolved = Self.resolvedSnapshotTerminalScrollback(
            capturedScrollback: capturedScrollback,
            fallbackScrollback: fallback,
            allowFallbackScrollback: allowFallbackScrollback
        )
#if DEBUG
        if debugFallback != nil {
            debugSessionSnapshotScrollbackFallbackPanelIds.remove(panelId)
            debugSessionSnapshotSyntheticScrollbackByPanelId.removeValue(forKey: panelId)
            return resolved
        }
#endif
        if let resolved {
            restoredTerminalScrollbackByPanelId[panelId] = resolved
        } else {
            restoredTerminalScrollbackByPanelId.removeValue(forKey: panelId)
        }
        return resolved
    }

#if DEBUG
    func debugSeedSessionSnapshotScrollback(charactersPerTerminal: Int) -> (terminals: Int, characters: Int) {
        for panelId in debugSessionSnapshotScrollbackFallbackPanelIds {
            debugSessionSnapshotSyntheticScrollbackByPanelId.removeValue(forKey: panelId)
        }
        debugSessionSnapshotScrollbackFallbackPanelIds.removeAll(keepingCapacity: false)
        debugSessionSnapshotSyntheticScrollbackByPanelId.removeAll(keepingCapacity: false)

        let targetCharacters = min(
            max(0, charactersPerTerminal),
            SessionPersistencePolicy.maxScrollbackCharactersPerTerminal
        )
        guard targetCharacters > 0 else { return (0, 0) }

        var terminalCount = 0
        var totalCharacters = 0
        for panelId in panels.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard panels[panelId] is TerminalPanel else { continue }
            let header = "cmux perf synthetic scrollback workspace=\(id.uuidString) panel=\(panelId.uuidString)\n"
            let paddingCount = max(0, targetCharacters - header.count)
            let scrollback = String((header + String(repeating: "s", count: paddingCount)).prefix(targetCharacters))
            debugSessionSnapshotSyntheticScrollbackByPanelId[panelId] = scrollback
            debugSessionSnapshotScrollbackFallbackPanelIds.insert(panelId)
            terminalCount += 1
            totalCharacters += scrollback.count
        }
        return (terminalCount, totalCharacters)
    }
#endif

}
