import AppKit
import CmuxSocketControl
import Bonsplit
import Combine
@_spi(CmuxHostTransport) import CmuxExtensionKit
import CmuxSidebarProviderKit
import CmuxExtensionSidebarExamples
import CmuxSettings
import CmuxSettingsUI
import CmuxSidebarRemoteRender
import CmuxSwiftRender
import CmuxSwiftRenderUI
import CmuxUpdater
import CmuxUpdaterUI
import ImageIO
import Observation
import SwiftUI
import ObjectiveC
import UniformTypeIdentifiers
import WebKit


// MARK: - Command palette forkable agent availability probes
extension ContentView {
    func commandPaletteCachedCommandsContext() -> CommandPaletteCommandsContext {
        commandPaletteCommandsContext(
            terminalOpenTargets: commandPaletteTerminalOpenTargetAvailability
        )
    }

    func resolveCommandPaletteTerminalOpenTargets(
        for scope: CommandPaletteListScope
    ) -> Set<TerminalDirectoryOpenTarget> {
        guard scope == .commands,
              focusedPanelContext?.panel.panelType == .terminal else {
            return []
        }
        return TerminalDirectoryOpenTarget.availableTargets()
    }

    static func commandPaletteForkableAgentPanelKey(workspaceId: UUID, panelId: UUID) -> String {
        "\(workspaceId.uuidString):\(panelId.uuidString)"
    }

    enum CommandPaletteForkSnapshotAvailability {
        case unsupported
        case supportedWithoutProbe
        case requiresProbe
    }

    static func commandPaletteSnapshotForkAvailability(
        _ snapshot: SessionRestorableAgentSnapshot,
        isRemoteTerminal: Bool = false
    ) -> CommandPaletteForkSnapshotAvailability {
        guard snapshot.forkCommand != nil else { return .unsupported }
        if isRemoteTerminal,
           snapshot.forkStartupInput(allowLauncherScript: false) == nil {
            return .unsupported
        }
        switch snapshot.kind {
        case .claude, .codex:
            return .supportedWithoutProbe
        case .opencode:
            return snapshot.launchCommand?.launcher == "omo" || isRemoteTerminal ? .supportedWithoutProbe : .requiresProbe
        default:
            return .unsupported
        }
    }

    static func commandPaletteForkSnapshotFingerprint(
        _ snapshot: SessionRestorableAgentSnapshot
    ) -> String {
        let launchCommand = snapshot.launchCommand
        let launchArguments = launchCommand?.arguments.joined(separator: "\u{1f}") ?? ""
        let parts: [String] = [
            snapshot.kind.rawValue,
            snapshot.sessionId,
            snapshot.workingDirectory ?? "",
            launchCommand?.launcher ?? "",
            launchCommand?.executablePath ?? "",
            launchArguments,
            launchCommand?.workingDirectory ?? "",
            launchCommand?.source ?? "",
            snapshot.forkCommand ?? ""
        ]
        return parts.joined(separator: "\u{1e}")
    }

    static func commandPaletteForkCacheFingerprint(
        snapshot: SessionRestorableAgentSnapshot,
        fallbackFingerprint: String?
    ) -> String {
        fallbackFingerprint ?? commandPaletteForkSnapshotFingerprint(snapshot)
    }

    static func commandPaletteForkableAgentProbeResultMatches(
        panelKey: String,
        supportedPanelKeys: Set<String>,
        supportedRemoteContextsByPanelKey: [String: Bool],
        snapshotFingerprintsByPanelKey: [String: String],
        expectedSnapshotFingerprint: String?,
        isRemoteTerminal: Bool
    ) -> Bool {
        guard supportedPanelKeys.contains(panelKey),
              supportedRemoteContextsByPanelKey[panelKey] == isRemoteTerminal else {
            return false
        }
        guard let expectedSnapshotFingerprint else {
            return true
        }
        return snapshotFingerprintsByPanelKey[panelKey] == expectedSnapshotFingerprint
    }

    static func commandPaletteShouldReuseForkableAgentProbeResult(
        panelKey: String,
        supportedPanelKeys: Set<String>,
        supportedRemoteContextsByPanelKey: [String: Bool],
        snapshotFingerprintsByPanelKey: [String: String],
        expectedSnapshotFingerprint: String?,
        isRemoteTerminal: Bool,
        cachedResultHadFallback: Bool,
        panelChanged: Bool
    ) -> Bool {
        !panelChanged && !cachedResultHadFallback && commandPaletteForkableAgentProbeResultMatches(
            panelKey: panelKey,
            supportedPanelKeys: supportedPanelKeys,
            supportedRemoteContextsByPanelKey: supportedRemoteContextsByPanelKey,
            snapshotFingerprintsByPanelKey: snapshotFingerprintsByPanelKey,
            expectedSnapshotFingerprint: expectedSnapshotFingerprint,
            isRemoteTerminal: isRemoteTerminal
        )
    }

    static func commandPaletteShouldClearForkableAgentProbeResultBeforeProbe(
        panelKey: String,
        supportedPanelKeys: Set<String>,
        supportedRemoteContextsByPanelKey: [String: Bool],
        snapshotFingerprintsByPanelKey: [String: String],
        expectedSnapshotFingerprint: String?,
        isRemoteTerminal: Bool,
        cachedResultHadFallback: Bool,
        panelChanged: Bool
    ) -> Bool {
        panelChanged || cachedResultHadFallback || !commandPaletteForkableAgentProbeResultMatches(
            panelKey: panelKey,
            supportedPanelKeys: supportedPanelKeys,
            supportedRemoteContextsByPanelKey: supportedRemoteContextsByPanelKey,
            snapshotFingerprintsByPanelKey: snapshotFingerprintsByPanelKey,
            expectedSnapshotFingerprint: expectedSnapshotFingerprint,
            isRemoteTerminal: isRemoteTerminal
        )
    }

    static func commandPaletteForkMatchedFallbackProbeResultHadFallback(
        cachedResultHadFallback: Bool?
    ) -> Bool {
        cachedResultHadFallback ?? true
    }

    static func commandPalettePanelHasForkableAgent(
        workspaceId: UUID,
        panelId: UUID,
        supportedPanelKeys: Set<String>,
        supportedRemoteContextsByPanelKey: [String: Bool] = [:],
        fallbackSnapshot: SessionRestorableAgentSnapshot?,
        isRemoteTerminal: Bool = false
    ) -> Bool {
        let panelKey = commandPaletteForkableAgentPanelKey(
            workspaceId: workspaceId,
            panelId: panelId
        )
        if supportedPanelKeys.contains(panelKey) {
            if let supportedRemoteContext = supportedRemoteContextsByPanelKey[panelKey],
               supportedRemoteContext != isRemoteTerminal {
                return false
            }
            if let fallbackSnapshot {
                return commandPaletteSnapshotForkAvailability(
                    fallbackSnapshot,
                    isRemoteTerminal: isRemoteTerminal
                ) != .unsupported
            }
            return true
        }
        return false
    }

    func refreshCommandPaletteForkableAgentAvailabilityIfNeeded(scope: CommandPaletteListScope) {
        guard scope == .commands,
              let panelContext = focusedPanelContext,
              panelContext.panel.panelType == .terminal else {
            commandPaletteForkableAgentActivePanelKey = nil
            cancelCommandPaletteForkableAgentAvailabilityProbe()
            return
        }

        let workspaceId = panelContext.workspace.id
        let panelId = panelContext.panelId
        let isRemoteTerminal = panelContext.workspace.isRemoteTerminalSurface(panelId)
        let panelKey = Self.commandPaletteForkableAgentPanelKey(workspaceId: workspaceId, panelId: panelId)
        let panelChanged = commandPaletteForkableAgentActivePanelKey != panelKey
        commandPaletteForkableAgentActivePanelKey = panelKey
        let fallbackSnapshot = panelContext.workspace.restoredAgentSnapshotsByPanelId[panelId]

        if let fallbackSnapshot {
            let fallbackFingerprint = Self.commandPaletteForkSnapshotFingerprint(fallbackSnapshot)
            if let cachedFingerprint = commandPaletteForkableAgentSnapshotFingerprintsByPanelKey[panelKey],
               cachedFingerprint != fallbackFingerprint {
                cancelCommandPaletteForkableAgentAvailabilityProbe(for: panelKey)
                commandPaletteForkableAgentSupportedPanelKeys.remove(panelKey)
                commandPaletteForkableAgentSnapshotsByPanelKey.removeValue(forKey: panelKey)
                commandPaletteForkableAgentSnapshotFingerprintsByPanelKey.removeValue(forKey: panelKey)
                commandPaletteForkableAgentRemoteContextsByPanelKey.removeValue(forKey: panelKey)
                commandPaletteForkableAgentResultHadFallbackByPanelKey.removeValue(forKey: panelKey)
            }
            switch Self.commandPaletteSnapshotForkAvailability(
                fallbackSnapshot,
                isRemoteTerminal: isRemoteTerminal
            ) {
            case .supportedWithoutProbe:
                let probeResultMatches = Self.commandPaletteForkableAgentProbeResultMatches(
                    panelKey: panelKey,
                    supportedPanelKeys: commandPaletteForkableAgentSupportedPanelKeys,
                    supportedRemoteContextsByPanelKey: commandPaletteForkableAgentRemoteContextsByPanelKey,
                    snapshotFingerprintsByPanelKey: commandPaletteForkableAgentSnapshotFingerprintsByPanelKey,
                    expectedSnapshotFingerprint: fallbackFingerprint,
                    isRemoteTerminal: isRemoteTerminal
                )
                if probeResultMatches {
                    commandPaletteForkableAgentSupportedPanelKeys.insert(panelKey)
                    commandPaletteForkableAgentRemoteContextsByPanelKey[panelKey] = isRemoteTerminal
                    commandPaletteForkableAgentResultHadFallbackByPanelKey[panelKey] =
                        Self.commandPaletteForkMatchedFallbackProbeResultHadFallback(
                            cachedResultHadFallback: commandPaletteForkableAgentResultHadFallbackByPanelKey[panelKey]
                        )
                } else {
                    commandPaletteForkableAgentSupportedPanelKeys.remove(panelKey)
                    commandPaletteForkableAgentSnapshotsByPanelKey.removeValue(forKey: panelKey)
                    commandPaletteForkableAgentSnapshotFingerprintsByPanelKey.removeValue(forKey: panelKey)
                    commandPaletteForkableAgentRemoteContextsByPanelKey.removeValue(forKey: panelKey)
                    commandPaletteForkableAgentResultHadFallbackByPanelKey.removeValue(forKey: panelKey)
                }
                if panelChanged || !probeResultMatches {
                    startCommandPaletteForkableAgentAvailabilityProbe(
                        panelKey: panelKey,
                        workspaceId: workspaceId,
                        panelId: panelId,
                        fallbackSnapshot: fallbackSnapshot,
                        fallbackFingerprint: fallbackFingerprint,
                        isRemoteTerminal: isRemoteTerminal
                    )
                }
                return
            case .unsupported:
                cancelCommandPaletteForkableAgentAvailabilityProbe(for: panelKey)
                commandPaletteForkableAgentSupportedPanelKeys.remove(panelKey)
                commandPaletteForkableAgentSnapshotsByPanelKey.removeValue(forKey: panelKey)
                commandPaletteForkableAgentSnapshotFingerprintsByPanelKey.removeValue(forKey: panelKey)
                commandPaletteForkableAgentRemoteContextsByPanelKey.removeValue(forKey: panelKey)
                commandPaletteForkableAgentResultHadFallbackByPanelKey.removeValue(forKey: panelKey)
                return
            case .requiresProbe:
                let probeResultMatches = Self.commandPaletteForkableAgentProbeResultMatches(
                    panelKey: panelKey,
                    supportedPanelKeys: commandPaletteForkableAgentSupportedPanelKeys,
                    supportedRemoteContextsByPanelKey: commandPaletteForkableAgentRemoteContextsByPanelKey,
                    snapshotFingerprintsByPanelKey: commandPaletteForkableAgentSnapshotFingerprintsByPanelKey,
                    expectedSnapshotFingerprint: fallbackFingerprint,
                    isRemoteTerminal: isRemoteTerminal
                )
                if probeResultMatches {
                    commandPaletteForkableAgentResultHadFallbackByPanelKey[panelKey] =
                        Self.commandPaletteForkMatchedFallbackProbeResultHadFallback(
                            cachedResultHadFallback: commandPaletteForkableAgentResultHadFallbackByPanelKey[panelKey]
                        )
                }
                if probeResultMatches && !panelChanged {
                    return
                }
                if !probeResultMatches {
                    commandPaletteForkableAgentSupportedPanelKeys.remove(panelKey)
                    commandPaletteForkableAgentSnapshotsByPanelKey.removeValue(forKey: panelKey)
                    commandPaletteForkableAgentSnapshotFingerprintsByPanelKey.removeValue(forKey: panelKey)
                    commandPaletteForkableAgentRemoteContextsByPanelKey.removeValue(forKey: panelKey)
                    commandPaletteForkableAgentResultHadFallbackByPanelKey.removeValue(forKey: panelKey)
                }
                startCommandPaletteForkableAgentAvailabilityProbe(
                    panelKey: panelKey,
                    workspaceId: workspaceId,
                    panelId: panelId,
                    fallbackSnapshot: fallbackSnapshot,
                    fallbackFingerprint: fallbackFingerprint,
                    isRemoteTerminal: isRemoteTerminal
                )
                return
            }
        }

        let cachedResultHadFallback = commandPaletteForkableAgentResultHadFallbackByPanelKey[panelKey] == true
        if Self.commandPaletteShouldReuseForkableAgentProbeResult(
            panelKey: panelKey,
            supportedPanelKeys: commandPaletteForkableAgentSupportedPanelKeys,
            supportedRemoteContextsByPanelKey: commandPaletteForkableAgentRemoteContextsByPanelKey,
            snapshotFingerprintsByPanelKey: commandPaletteForkableAgentSnapshotFingerprintsByPanelKey,
            expectedSnapshotFingerprint: nil,
            isRemoteTerminal: isRemoteTerminal,
            cachedResultHadFallback: cachedResultHadFallback,
            panelChanged: panelChanged
        ) {
            return
        }

        if Self.commandPaletteShouldClearForkableAgentProbeResultBeforeProbe(
            panelKey: panelKey,
            supportedPanelKeys: commandPaletteForkableAgentSupportedPanelKeys,
            supportedRemoteContextsByPanelKey: commandPaletteForkableAgentRemoteContextsByPanelKey,
            snapshotFingerprintsByPanelKey: commandPaletteForkableAgentSnapshotFingerprintsByPanelKey,
            expectedSnapshotFingerprint: nil,
            isRemoteTerminal: isRemoteTerminal,
            cachedResultHadFallback: cachedResultHadFallback,
            panelChanged: panelChanged
        ) {
            commandPaletteForkableAgentSupportedPanelKeys.remove(panelKey)
            commandPaletteForkableAgentSnapshotsByPanelKey.removeValue(forKey: panelKey)
            commandPaletteForkableAgentSnapshotFingerprintsByPanelKey.removeValue(forKey: panelKey)
            commandPaletteForkableAgentRemoteContextsByPanelKey.removeValue(forKey: panelKey)
            commandPaletteForkableAgentResultHadFallbackByPanelKey.removeValue(forKey: panelKey)
        }
        startCommandPaletteForkableAgentAvailabilityProbe(
            panelKey: panelKey,
            workspaceId: workspaceId,
            panelId: panelId,
            fallbackSnapshot: nil,
            fallbackFingerprint: nil,
            isRemoteTerminal: isRemoteTerminal
        )
    }

    private func startCommandPaletteForkableAgentAvailabilityProbe(
        panelKey: String,
        workspaceId: UUID,
        panelId: UUID,
        fallbackSnapshot: SessionRestorableAgentSnapshot?,
        fallbackFingerprint: String?,
        isRemoteTerminal: Bool
    ) {
        let probeFingerprint = "\(fallbackFingerprint ?? "")\u{1f}\(isRemoteTerminal ? "remote" : "local")"
        if let task = commandPaletteForkableAgentAvailabilityTasksByPanelKey[panelKey] {
            guard commandPaletteForkableAgentProbeFingerprintsByPanelKey[panelKey] != probeFingerprint else { return }
            task.cancel()
            commandPaletteForkableAgentAvailabilityTasksByPanelKey.removeValue(forKey: panelKey)
            commandPaletteForkableAgentProbeIDsByPanelKey.removeValue(forKey: panelKey)
            commandPaletteForkableAgentProbeFingerprintsByPanelKey.removeValue(forKey: panelKey)
        }
        let probeID = UUID()
        commandPaletteForkableAgentProbeIDsByPanelKey[panelKey] = probeID
        commandPaletteForkableAgentProbeFingerprintsByPanelKey[panelKey] = probeFingerprint

        commandPaletteForkableAgentAvailabilityTasksByPanelKey[panelKey] = Task {
            let index = await RestorableAgentSessionIndex.loadIncludingProcessDetectedSnapshots()
            guard !Task.isCancelled else { return }
            let indexSnapshot = index.snapshot(workspaceId: workspaceId, panelId: panelId)
            let snapshot = indexSnapshot ?? fallbackSnapshot
            let supportsFork: Bool
            if let snapshot {
                supportsFork = await AgentForkSupport.supportsFork(
                    snapshot: snapshot,
                    isRemoteContext: isRemoteTerminal
                )
            } else {
                supportsFork = false
            }
            guard !Task.isCancelled else { return }

            await MainActor.run {
                guard commandPaletteForkableAgentProbeIDsByPanelKey[panelKey] == probeID else { return }
                guard commandPaletteForkableAgentProbeFingerprintsByPanelKey[panelKey] == probeFingerprint else { return }
                if let fallbackFingerprint,
                   let currentContext = focusedPanelContext,
                   currentContext.workspace.id == workspaceId,
                   currentContext.panelId == panelId,
                   let currentFallbackSnapshot = currentContext.workspace.restoredAgentSnapshotsByPanelId[panelId],
                   Self.commandPaletteForkSnapshotFingerprint(currentFallbackSnapshot) != fallbackFingerprint {
                    commandPaletteForkableAgentProbeIDsByPanelKey.removeValue(forKey: panelKey)
                    commandPaletteForkableAgentProbeFingerprintsByPanelKey.removeValue(forKey: panelKey)
                    commandPaletteForkableAgentAvailabilityTasksByPanelKey.removeValue(forKey: panelKey)
                    return
                }
                let wasSupported = commandPaletteForkableAgentSupportedPanelKeys.contains(panelKey)
                let hadCachedSnapshot = commandPaletteForkableAgentSnapshotsByPanelKey[panelKey] != nil
                let shouldRefreshResults: Bool
                if supportsFork {
                    shouldRefreshResults = !wasSupported
                    commandPaletteForkableAgentSupportedPanelKeys.insert(panelKey)
                    commandPaletteForkableAgentRemoteContextsByPanelKey[panelKey] = isRemoteTerminal
                    if let snapshot {
                        commandPaletteForkableAgentSnapshotsByPanelKey[panelKey] = snapshot
                        commandPaletteForkableAgentSnapshotFingerprintsByPanelKey[panelKey] = Self.commandPaletteForkCacheFingerprint(
                            snapshot: snapshot,
                            fallbackFingerprint: fallbackFingerprint
                        )
                        commandPaletteForkableAgentResultHadFallbackByPanelKey[panelKey] =
                            indexSnapshot == nil && fallbackSnapshot != nil
                    }
                } else {
                    shouldRefreshResults = wasSupported || hadCachedSnapshot
                    commandPaletteForkableAgentSupportedPanelKeys.remove(panelKey)
                    commandPaletteForkableAgentSnapshotsByPanelKey.removeValue(forKey: panelKey)
                    commandPaletteForkableAgentSnapshotFingerprintsByPanelKey.removeValue(forKey: panelKey)
                    commandPaletteForkableAgentRemoteContextsByPanelKey.removeValue(forKey: panelKey)
                    commandPaletteForkableAgentResultHadFallbackByPanelKey.removeValue(forKey: panelKey)
                }
                commandPaletteForkableAgentProbeIDsByPanelKey.removeValue(forKey: panelKey)
                commandPaletteForkableAgentProbeFingerprintsByPanelKey.removeValue(forKey: panelKey)
                commandPaletteForkableAgentAvailabilityTasksByPanelKey.removeValue(forKey: panelKey)
                if shouldRefreshResults,
                   isCommandPalettePresented,
                   commandPaletteForkableAgentActivePanelKey == panelKey {
                    scheduleCommandPaletteResultsRefresh(
                        query: commandPaletteQuery,
                        forceSearchCorpusRefresh: true
                    )
                }
            }
        }
    }

    func cancelCommandPaletteForkableAgentAvailabilityProbe() {
        for task in commandPaletteForkableAgentAvailabilityTasksByPanelKey.values {
            task.cancel()
        }
        commandPaletteForkableAgentAvailabilityTasksByPanelKey.removeAll()
        commandPaletteForkableAgentProbeIDsByPanelKey.removeAll()
        commandPaletteForkableAgentProbeFingerprintsByPanelKey.removeAll()
    }

    func cancelCommandPaletteForkableAgentAvailabilityProbe(for panelKey: String) {
        commandPaletteForkableAgentAvailabilityTasksByPanelKey.removeValue(forKey: panelKey)?.cancel()
        commandPaletteForkableAgentProbeIDsByPanelKey.removeValue(forKey: panelKey)
        commandPaletteForkableAgentProbeFingerprintsByPanelKey.removeValue(forKey: panelKey)
    }

    func refreshCachedDefaultTerminalStatus(refreshSearchCorpusIfPresented: Bool = true) {
        let isDefault = DefaultTerminalRegistration.currentStatus().isDefault
        guard cachedDefaultTerminalIsDefault != isDefault else { return }

        cachedDefaultTerminalIsDefault = isDefault
        cachedCommandPaletteFingerprint = nil
        if refreshSearchCorpusIfPresented, isCommandPalettePresented {
            scheduleCommandPaletteResultsRefresh(forceSearchCorpusRefresh: true, preservePendingActivation: true)
            syncCommandPaletteOverlayCommandListState()
            syncCommandPaletteDebugStateForObservedWindow()
        }
    }

}
