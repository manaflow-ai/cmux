import AppKit
import Bonsplit
import CmuxPanes
import Foundation

extension ContentView {
    func forkFocusedAgentConversationRight() {
        forkFocusedAgentConversation(.right)
    }

    func forkFocusedAgentConversationLeft() {
        forkFocusedAgentConversation(.left)
    }

    func forkFocusedAgentConversationTop() {
        forkFocusedAgentConversation(.top)
    }

    func forkFocusedAgentConversationBottom() {
        forkFocusedAgentConversation(.bottom)
    }

    func forkFocusedAgentConversationToNewTab() {
        forkFocusedAgentConversation(.newTab)
    }

    func forkFocusedAgentConversationToNewWorkspace() {
        forkFocusedAgentConversation(.newWorkspace)
    }

    private func forkFocusedAgentConversation(_ destination: AgentConversationForkDestination) {
        guard let currentContext = focusedPanelContext,
              currentContext.panel.panelType == .terminal else {
            NSSound.beep()
            return
        }

        let workspaceId = currentContext.workspace.id
        let panelId = currentContext.panelId
        let panelKey = Self.commandPaletteForkableAgentPanelKey(
            workspaceId: workspaceId,
            panelId: panelId
        )

        let allowsAgentContinuation = currentContext.workspace.allowsAgentContinuation(forPanelId: panelId)
        let fallbackSnapshot = currentContext.workspace.restoredAgentSnapshotForContinuation(panelId: panelId)
        let isRemoteContext = currentContext.workspace.isRemoteTerminalSurface(panelId)
        let selection = Self.commandPaletteImmediateForkExecutionSnapshotSelection(
            workspaceId: workspaceId,
            panelId: panelId,
            isRemoteTerminal: isRemoteContext,
            supportedPanelKeys: commandPaletteForkableAgentSupportedPanelKeys,
            supportedRemoteContextsByPanelKey: commandPaletteForkableAgentRemoteContextsByPanelKey,
            snapshotFingerprintsByPanelKey: commandPaletteForkableAgentSnapshotFingerprintsByPanelKey,
            fallbackSnapshot: fallbackSnapshot,
            cachedSnapshot: commandPaletteForkableAgentSnapshotsByPanelKey[panelKey],
            allowsAgentContinuation: allowsAgentContinuation
        )
        guard let selection else {
            clearCommandPaletteForkableAgentCache(panelKey: panelKey)
            NSSound.beep()
            return
        }
        let snapshot = selection.snapshot

        let fallbackFingerprint = fallbackSnapshot.map(Self.commandPaletteForkSnapshotFingerprint)
        commandPaletteForkableAgentSupportedPanelKeys.insert(panelKey)
        commandPaletteForkableAgentSnapshotsByPanelKey[panelKey] = snapshot
        commandPaletteForkableAgentSnapshotFingerprintsByPanelKey[panelKey] = Self.commandPaletteForkCacheFingerprint(
            snapshot: snapshot,
            fallbackFingerprint: fallbackFingerprint
        )
        commandPaletteForkableAgentRemoteContextsByPanelKey[panelKey] = isRemoteContext
        commandPaletteForkableAgentResultHadFallbackByPanelKey[panelKey] = selection.usedFallbackSnapshot

        let didFork: Bool
        if let direction = destination.splitDirection {
            didFork = currentContext.workspace.forkAgentConversation(
                fromPanelId: panelId,
                snapshot: snapshot,
                direction: direction
            ) != nil
        } else {
            switch destination {
            case .newTab:
                guard let anchorTabId = currentContext.workspace.surfaceIdFromPanelId(panelId),
                      let paneId = currentContext.workspace.paneId(forPanelId: panelId) else {
                    clearCommandPaletteForkableAgentCache(panelKey: panelKey)
                    NSSound.beep()
                    return
                }
                didFork = currentContext.workspace.forkAgentConversationToNewTab(
                    fromPanelId: panelId,
                    snapshot: snapshot,
                    anchorTabId: anchorTabId,
                    paneId: paneId
                ) != nil
            case .newWorkspace:
                guard let launch = currentContext.workspace.forkAgentWorkspaceLaunch(
                    fromPanelId: panelId,
                    snapshot: snapshot
                ) else {
                    clearCommandPaletteForkableAgentCache(panelKey: panelKey)
                    NSSound.beep()
                    return
                }
                let forkWorkspace = tabManager.addWorkspace(
                    workingDirectory: launch.terminalWorkingDirectory,
                    initialTerminalCommand: launch.initialTerminalCommand,
                    initialTerminalInput: launch.initialTerminalInput,
                    initialTerminalEnvironment: launch.initialTerminalEnvironment,
                    inheritWorkingDirectory: launch.terminalWorkingDirectory != nil,
                    autoWelcomeIfNeeded: false
                )
                if let remoteConfiguration = launch.remoteConfiguration {
                    forkWorkspace.configureRemoteConnection(
                        remoteConfiguration,
                        autoConnect: launch.autoConnectRemoteConfiguration
                    )
                }
                if let workingDirectory = launch.workingDirectory,
                   launch.terminalWorkingDirectory == nil,
                   let forkPanelId = forkWorkspace.focusedPanelId {
                    forkWorkspace.updatePanelDirectory(panelId: forkPanelId, directory: workingDirectory)
                }
                didFork = true
            case .right, .left, .top, .bottom:
                didFork = false
            }
        }

        guard didFork else {
            clearCommandPaletteForkableAgentCache(panelKey: panelKey)
            NSSound.beep()
            return
        }
    }

    private func clearCommandPaletteForkableAgentCache(panelKey: String) {
        commandPaletteForkableAgentSupportedPanelKeys.remove(panelKey)
        commandPaletteForkableAgentSnapshotsByPanelKey.removeValue(forKey: panelKey)
        commandPaletteForkableAgentSnapshotFingerprintsByPanelKey.removeValue(forKey: panelKey)
        commandPaletteForkableAgentRemoteContextsByPanelKey.removeValue(forKey: panelKey)
        commandPaletteForkableAgentResultHadFallbackByPanelKey.removeValue(forKey: panelKey)
    }
}

extension ContentView {
    struct CommandPaletteForkSnapshotSelection {
        let snapshot: SessionRestorableAgentSnapshot
        let usedFallbackSnapshot: Bool
    }

    static func commandPalettePanelHasForkableAgent(
        workspaceId: UUID,
        panelId: UUID,
        supportedPanelKeys: Set<String>,
        supportedRemoteContextsByPanelKey: [String: Bool] = [:],
        fallbackSnapshot: SessionRestorableAgentSnapshot?,
        isRemoteTerminal: Bool = false,
        allowsAgentContinuation: Bool
    ) -> Bool {
        guard allowsAgentContinuation else { return false }
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

    static func commandPaletteImmediateForkExecutionSnapshot(
        workspaceId: UUID,
        panelId: UUID,
        isRemoteTerminal: Bool,
        supportedPanelKeys: Set<String>,
        supportedRemoteContextsByPanelKey: [String: Bool],
        snapshotFingerprintsByPanelKey: [String: String],
        fallbackSnapshot: SessionRestorableAgentSnapshot?,
        cachedSnapshot: SessionRestorableAgentSnapshot?,
        allowsAgentContinuation: Bool
    ) -> SessionRestorableAgentSnapshot? {
        commandPaletteImmediateForkExecutionSnapshotSelection(
            workspaceId: workspaceId,
            panelId: panelId,
            isRemoteTerminal: isRemoteTerminal,
            supportedPanelKeys: supportedPanelKeys,
            supportedRemoteContextsByPanelKey: supportedRemoteContextsByPanelKey,
            snapshotFingerprintsByPanelKey: snapshotFingerprintsByPanelKey,
            fallbackSnapshot: fallbackSnapshot,
            cachedSnapshot: cachedSnapshot,
            allowsAgentContinuation: allowsAgentContinuation
        )?.snapshot
    }

    static func commandPaletteImmediateForkExecutionSnapshotSelection(
        workspaceId: UUID,
        panelId: UUID,
        isRemoteTerminal: Bool,
        supportedPanelKeys: Set<String>,
        supportedRemoteContextsByPanelKey: [String: Bool],
        snapshotFingerprintsByPanelKey: [String: String],
        fallbackSnapshot: SessionRestorableAgentSnapshot?,
        cachedSnapshot: SessionRestorableAgentSnapshot?,
        allowsAgentContinuation: Bool
    ) -> CommandPaletteForkSnapshotSelection? {
        guard allowsAgentContinuation else { return nil }
        let panelKey = commandPaletteForkableAgentPanelKey(
            workspaceId: workspaceId,
            panelId: panelId
        )
        func verifiedCachedSnapshot(expectedFingerprint: String?) -> SessionRestorableAgentSnapshot? {
            guard let cachedSnapshot,
                  supportedPanelKeys.contains(panelKey),
                  supportedRemoteContextsByPanelKey[panelKey] == isRemoteTerminal else {
                return nil
            }
            if let expectedFingerprint,
               snapshotFingerprintsByPanelKey[panelKey] != expectedFingerprint {
                return nil
            }
            guard commandPaletteSnapshotForkAvailability(
                cachedSnapshot,
                isRemoteTerminal: isRemoteTerminal
            ) != .unsupported else {
                return nil
            }
            return cachedSnapshot
        }

        if let fallbackSnapshot {
            let fallbackFingerprint = commandPaletteForkSnapshotFingerprint(fallbackSnapshot)
            switch commandPaletteSnapshotForkAvailability(
                fallbackSnapshot,
                isRemoteTerminal: isRemoteTerminal
            ) {
            case .supportedWithoutProbe:
                guard commandPaletteForkableAgentProbeResultMatches(
                    panelKey: panelKey,
                    supportedPanelKeys: supportedPanelKeys,
                    supportedRemoteContextsByPanelKey: supportedRemoteContextsByPanelKey,
                    snapshotFingerprintsByPanelKey: snapshotFingerprintsByPanelKey,
                    expectedSnapshotFingerprint: fallbackFingerprint,
                    isRemoteTerminal: isRemoteTerminal
                ) else {
                    return nil
                }
                if let cachedSnapshot = verifiedCachedSnapshot(expectedFingerprint: fallbackFingerprint) {
                    return CommandPaletteForkSnapshotSelection(
                        snapshot: cachedSnapshot,
                        usedFallbackSnapshot: false
                    )
                }
                return CommandPaletteForkSnapshotSelection(
                    snapshot: fallbackSnapshot,
                    usedFallbackSnapshot: true
                )
            case .unsupported:
                return nil
            case .requiresProbe:
                guard commandPaletteForkableAgentProbeResultMatches(
                    panelKey: panelKey,
                    supportedPanelKeys: supportedPanelKeys,
                    supportedRemoteContextsByPanelKey: supportedRemoteContextsByPanelKey,
                    snapshotFingerprintsByPanelKey: snapshotFingerprintsByPanelKey,
                    expectedSnapshotFingerprint: fallbackFingerprint,
                    isRemoteTerminal: isRemoteTerminal
                ) else {
                    return nil
                }
                if let cachedSnapshot = verifiedCachedSnapshot(expectedFingerprint: fallbackFingerprint) {
                    return CommandPaletteForkSnapshotSelection(
                        snapshot: cachedSnapshot,
                        usedFallbackSnapshot: false
                    )
                }
                return CommandPaletteForkSnapshotSelection(
                    snapshot: fallbackSnapshot,
                    usedFallbackSnapshot: true
                )
            }
        }

        guard let cachedSnapshot = verifiedCachedSnapshot(expectedFingerprint: nil) else {
            return nil
        }
        switch commandPaletteSnapshotForkAvailability(
            cachedSnapshot,
            isRemoteTerminal: isRemoteTerminal
        ) {
        case .supportedWithoutProbe, .requiresProbe:
            return CommandPaletteForkSnapshotSelection(
                snapshot: cachedSnapshot,
                usedFallbackSnapshot: false
            )
        case .unsupported:
            return nil
        }
    }
}

enum AgentConversationForkDestination: String, CaseIterable, Identifiable, Sendable {
    case right
    case left
    case top
    case bottom
    case newTab
    case newWorkspace

    var id: String { rawValue }

    static let defaultDestination: AgentConversationForkDestination = .right

    init(tabContextAction: TabContextAction) {
        switch tabContextAction {
        case .forkConversationLeft:
            self = .left
        case .forkConversationTop:
            self = .top
        case .forkConversationBottom:
            self = .bottom
        case .forkConversationNewTab:
            self = .newTab
        case .forkConversationNewWorkspace:
            self = .newWorkspace
        case .forkConversationRight:
            self = .right
        default:
            self = .defaultDestination
        }
    }

    var tabContextAction: TabContextAction {
        switch self {
        case .right:
            return .forkConversationRight
        case .left:
            return .forkConversationLeft
        case .top:
            return .forkConversationTop
        case .bottom:
            return .forkConversationBottom
        case .newTab:
            return .forkConversationNewTab
        case .newWorkspace:
            return .forkConversationNewWorkspace
        }
    }

    var commandPaletteCommandId: String {
        switch self {
        case .right:
            return "palette.forkAgentConversationRight"
        case .left:
            return "palette.forkAgentConversationLeft"
        case .top:
            return "palette.forkAgentConversationTop"
        case .bottom:
            return "palette.forkAgentConversationBottom"
        case .newTab:
            return "palette.forkAgentConversationNewTab"
        case .newWorkspace:
            return "palette.forkAgentConversationNewWorkspace"
        }
    }

    var title: String {
        switch self {
        case .right:
            return String(localized: "command.forkAgentConversationRight.title", defaultValue: "Fork Conversation to the Right")
        case .left:
            return String(localized: "command.forkAgentConversationLeft.title", defaultValue: "Fork Conversation to the Left")
        case .top:
            return String(localized: "command.forkAgentConversationTop.title", defaultValue: "Fork Conversation to the Top")
        case .bottom:
            return String(localized: "command.forkAgentConversationBottom.title", defaultValue: "Fork Conversation to the Bottom")
        case .newTab:
            return String(localized: "command.forkAgentConversationNewTab.title", defaultValue: "Fork Conversation to New Tab")
        case .newWorkspace:
            return String(localized: "command.forkAgentConversationNewWorkspace.title", defaultValue: "Fork Conversation to New Workspace")
        }
    }

    var settingsTitle: String {
        switch self {
        case .right:
            return String(localized: "forkConversation.destination.right", defaultValue: "Right Split")
        case .left:
            return String(localized: "forkConversation.destination.left", defaultValue: "Left Split")
        case .top:
            return String(localized: "forkConversation.destination.top", defaultValue: "Top Split")
        case .bottom:
            return String(localized: "forkConversation.destination.bottom", defaultValue: "Bottom Split")
        case .newTab:
            return String(localized: "forkConversation.destination.newTab", defaultValue: "New Tab")
        case .newWorkspace:
            return String(localized: "forkConversation.destination.newWorkspace", defaultValue: "New Workspace")
        }
    }

    var settingsDescription: String {
        switch self {
        case .right:
            return String(localized: "forkConversation.destination.right.description", defaultValue: "Right-click Fork Conversation creates a split to the right.")
        case .left:
            return String(localized: "forkConversation.destination.left.description", defaultValue: "Right-click Fork Conversation creates a split to the left.")
        case .top:
            return String(localized: "forkConversation.destination.top.description", defaultValue: "Right-click Fork Conversation creates a split above the current pane.")
        case .bottom:
            return String(localized: "forkConversation.destination.bottom.description", defaultValue: "Right-click Fork Conversation creates a split below the current pane.")
        case .newTab:
            return String(localized: "forkConversation.destination.newTab.description", defaultValue: "Right-click Fork Conversation creates a sibling tab in the current pane.")
        case .newWorkspace:
            return String(localized: "forkConversation.destination.newWorkspace.description", defaultValue: "Right-click Fork Conversation creates a new workspace.")
        }
    }

    var splitDirection: SplitDirection? {
        switch self {
        case .right:
            return .right
        case .left:
            return .left
        case .top:
            return .up
        case .bottom:
            return .down
        case .newTab, .newWorkspace:
            return nil
        }
    }
}

enum AgentConversationForkDefaultSettings {
    static let key = "agentConversationForkDefaultDestination"
    static let defaultDestination = AgentConversationForkDestination.defaultDestination

    static func current(defaults: UserDefaults = .standard) -> AgentConversationForkDestination {
        guard let raw = defaults.string(forKey: key),
              let destination = AgentConversationForkDestination(rawValue: raw) else {
            return defaultDestination
        }
        return destination
    }
}
