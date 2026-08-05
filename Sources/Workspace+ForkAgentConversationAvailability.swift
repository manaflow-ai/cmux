import Bonsplit
import CmuxPanes
import Foundation

enum AgentConversationForkSnapshotAvailability {
    case unsupported
    case supportedWithoutProbe
    case requiresProbe
}

enum AgentConversationForkSupport {
    static func snapshotAvailability(
        _ snapshot: SessionRestorableAgentSnapshot,
        isRemoteTerminal: Bool = false
    ) -> AgentConversationForkSnapshotAvailability {
        guard snapshot.forkCommand != nil else { return .unsupported }
        if isRemoteTerminal,
           snapshot.forkStartupInput(allowLauncherScript: false) == nil {
            return .unsupported
        }
        switch snapshot.kind {
        case .claude, .codex:
            return .supportedWithoutProbe
        case .pi:
            return isRemoteTerminal ? .unsupported : .requiresProbe
        case .opencode:
            return snapshot.launchCommand?.launcher == "omo" || isRemoteTerminal
                ? .supportedWithoutProbe
                : .requiresProbe
        case .custom:
            if AgentForkSupport.requiresLocalPiFamilyCapabilityProbe(snapshot) {
                return isRemoteTerminal ? .unsupported : .requiresProbe
            }
            return .supportedWithoutProbe
        default:
            return .unsupported
        }
    }

    static func snapshotFingerprint(
        _ snapshot: SessionRestorableAgentSnapshot,
        isRemoteTerminal: Bool = false
    ) -> String {
        let launchCommand = snapshot.launchCommand
        let launchArguments = launchCommand?.arguments.joined(separator: "\u{1f}") ?? ""
        let launchEnvironment = launchCommand?.environment.map { environment in
            environment.keys.sorted().map { key in
                "\(key)=\(environment[key] ?? "")"
            }.joined(separator: "\u{1f}")
        } ?? ""
        let parts = [
            snapshot.kind.rawValue,
            snapshot.sessionId,
            snapshot.workingDirectory ?? "",
            isRemoteTerminal ? "remote" : "local",
            launchCommand?.launcher ?? "",
            launchCommand?.executablePath ?? "",
            launchArguments,
            launchCommand?.workingDirectory ?? "",
            launchEnvironment,
            launchCommand?.source ?? "",
            snapshot.forkCommand ?? "",
        ]
        return parts.joined(separator: "\u{1e}")
    }

    static func availabilitySnapshotSource(
        liveIndexSnapshot: SessionRestorableAgentSnapshot?,
        fallbackSnapshot: SessionRestorableAgentSnapshot?,
        isRemoteTerminal: Bool = false
    ) -> (
        snapshot: SessionRestorableAgentSnapshot,
        snapshotFingerprint: String,
        validationFallbackSnapshot: SessionRestorableAgentSnapshot?,
        validationFallbackFingerprint: String?,
        resultHadFallback: Bool
    )? {
        guard let snapshot = liveIndexSnapshot ?? fallbackSnapshot else {
            return nil
        }
        let usesFallback = liveIndexSnapshot == nil
        let snapshotFingerprint = Self.snapshotFingerprint(
            snapshot,
            isRemoteTerminal: isRemoteTerminal
        )
        return (
            snapshot: snapshot,
            snapshotFingerprint: snapshotFingerprint,
            validationFallbackSnapshot: usesFallback ? fallbackSnapshot : nil,
            validationFallbackFingerprint: usesFallback ? snapshotFingerprint : nil,
            resultHadFallback: usesFallback && fallbackSnapshot != nil
        )
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
        case .right: .forkConversationRight
        case .left: .forkConversationLeft
        case .top: .forkConversationTop
        case .bottom: .forkConversationBottom
        case .newTab: .forkConversationNewTab
        case .newWorkspace: .forkConversationNewWorkspace
        }
    }

    var commandPaletteCommandId: String {
        switch self {
        case .right: "palette.forkAgentConversationRight"
        case .left: "palette.forkAgentConversationLeft"
        case .top: "palette.forkAgentConversationTop"
        case .bottom: "palette.forkAgentConversationBottom"
        case .newTab: "palette.forkAgentConversationNewTab"
        case .newWorkspace: "palette.forkAgentConversationNewWorkspace"
        }
    }

    var title: String {
        switch self {
        case .right:
            String(localized: "command.forkAgentConversationRight.title", defaultValue: "Fork Conversation to the Right")
        case .left:
            String(localized: "command.forkAgentConversationLeft.title", defaultValue: "Fork Conversation to the Left")
        case .top:
            String(localized: "command.forkAgentConversationTop.title", defaultValue: "Fork Conversation to the Top")
        case .bottom:
            String(localized: "command.forkAgentConversationBottom.title", defaultValue: "Fork Conversation to the Bottom")
        case .newTab:
            String(localized: "command.forkAgentConversationNewTab.title", defaultValue: "Fork Conversation to New Tab")
        case .newWorkspace:
            String(localized: "command.forkAgentConversationNewWorkspace.title", defaultValue: "Fork Conversation to New Workspace")
        }
    }

    var settingsTitle: String {
        switch self {
        case .right:
            String(localized: "forkConversation.destination.right", defaultValue: "Right Split")
        case .left:
            String(localized: "forkConversation.destination.left", defaultValue: "Left Split")
        case .top:
            String(localized: "forkConversation.destination.top", defaultValue: "Top Split")
        case .bottom:
            String(localized: "forkConversation.destination.bottom", defaultValue: "Bottom Split")
        case .newTab:
            String(localized: "forkConversation.destination.newTab", defaultValue: "New Tab")
        case .newWorkspace:
            String(localized: "forkConversation.destination.newWorkspace", defaultValue: "New Workspace")
        }
    }

    var settingsDescription: String {
        switch self {
        case .right:
            String(localized: "forkConversation.destination.right.description", defaultValue: "Right-click Fork Conversation creates a split to the right.")
        case .left:
            String(localized: "forkConversation.destination.left.description", defaultValue: "Right-click Fork Conversation creates a split to the left.")
        case .top:
            String(localized: "forkConversation.destination.top.description", defaultValue: "Right-click Fork Conversation creates a split above the current pane.")
        case .bottom:
            String(localized: "forkConversation.destination.bottom.description", defaultValue: "Right-click Fork Conversation creates a split below the current pane.")
        case .newTab:
            String(localized: "forkConversation.destination.newTab.description", defaultValue: "Right-click Fork Conversation creates a sibling tab in the current pane.")
        case .newWorkspace:
            String(localized: "forkConversation.destination.newWorkspace.description", defaultValue: "Right-click Fork Conversation creates a new workspace.")
        }
    }

    var splitDirection: SplitDirection? {
        switch self {
        case .right: .right
        case .left: .left
        case .top: .up
        case .bottom: .down
        case .newTab, .newWorkspace: nil
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

extension Workspace {
    func configureForkAgentConversationContextMenuAvailability() {
        bonsplitController.tabContextForkConversationAvailabilityProvider = { [weak self] tabId, _ in
            guard let self,
                  let panelId = self.panelIdFromSurfaceId(tabId) else { return .hidden }
            switch self.forkAgentConversationContextMenuPresentationAvailability(forPanelId: panelId) {
            case .available:
                return .available
            case .agentIndexRefreshing:
                return .refreshing
            case .notTerminalPanel,
                 .noAgentSnapshot,
                 .unsupported,
                 .requiresProbe:
                return .hidden
            }
        }
        bonsplitController.tabContextForkConversationAvailabilityRefreshHandler = { [weak self] tabId, _ in
            guard let self,
                  let panelId = self.panelIdFromSurfaceId(tabId) else { return }
            await self.resolveForkAgentConversationContextMenuAvailability(forPanelId: panelId)
        }
    }

    func forkAgentConversationContextMenuAvailability(
        forPanelId panelId: UUID
    ) -> WorkspaceForkAgentConversationAvailability {
        guard surfaceOwnershipTarget(for: panelId)?.panel is TerminalPanel else {
            return .notTerminalPanel
        }
        guard let snapshot = forkAgentConversationContextMenuCandidateSnapshot(forPanelId: panelId) else {
            return .noAgentSnapshot
        }
        switch AgentConversationForkSupport.snapshotAvailability(
            snapshot,
            isRemoteTerminal: isRemoteTerminalContext(panelId)
        ) {
        case .supportedWithoutProbe:
            return .available
        case .requiresProbe:
            return .requiresProbe
        case .unsupported:
            return .unsupported
        }
    }

    func forkAgentConversationContextMenuOpenAvailability(
        forPanelId panelId: UUID
    ) -> WorkspaceForkAgentConversationAvailability {
        forkAgentConversationContextMenuOpenAvailability(
            forPanelId: panelId,
            liveAgentIndex: .shared
        )
    }

    func forkAgentConversationContextMenuOpenAvailability(
        forPanelId panelId: UUID,
        liveAgentIndex: SharedLiveAgentIndex
    ) -> WorkspaceForkAgentConversationAvailability {
        forkAgentConversationContextMenuOpenSelection(
            forPanelId: panelId,
            liveAgentIndex: liveAgentIndex
        ).availability
    }

    func forkAgentConversationContextMenuPresentationAvailability(
        forPanelId panelId: UUID
    ) -> WorkspaceForkAgentConversationAvailability {
        forkAgentConversationContextMenuPresentationAvailability(
            forPanelId: panelId,
            liveAgentIndex: .shared
        )
    }

    func forkAgentConversationContextMenuPresentationAvailability(
        forPanelId panelId: UUID,
        liveAgentIndex: SharedLiveAgentIndex
    ) -> WorkspaceForkAgentConversationAvailability {
        let candidateAvailability = forkAgentConversationContextMenuAvailability(forPanelId: panelId)
        guard candidateAvailability == .available
            || candidateAvailability == .requiresProbe
            || candidateAvailability == .noAgentSnapshot else {
            return candidateAvailability
        }
        return forkAgentConversationContextMenuOpenAvailability(
            forPanelId: panelId,
            liveAgentIndex: liveAgentIndex
        )
    }

    func resolveForkAgentConversationContextMenuAvailability(
        forPanelId panelId: UUID
    ) async {
        await resolveForkAgentConversationContextMenuAvailability(
            forPanelId: panelId,
            liveAgentIndex: .shared
        )
    }

    func resolveForkAgentConversationContextMenuAvailability(
        forPanelId panelId: UUID,
        liveAgentIndex: SharedLiveAgentIndex
    ) async {
        let selection = forkAgentConversationContextMenuOpenSelection(
            forPanelId: panelId,
            liveAgentIndex: liveAgentIndex
        )
        guard selection.availability == .agentIndexRefreshing else { return }

        await liveAgentIndex.refreshForkAvailabilityNow(
            workspaceId: id,
            panelId: panelId,
            isRemoteContext: isRemoteTerminalContext(panelId),
            fallbackSnapshot: selection.validationFallbackSnapshot
        )
    }

    func forkAgentConversationContextMenuOpenSelection(
        forPanelId panelId: UUID
    ) -> (
        availability: WorkspaceForkAgentConversationAvailability,
        snapshot: SessionRestorableAgentSnapshot?,
        validationFallbackSnapshot: SessionRestorableAgentSnapshot?
    ) {
        forkAgentConversationContextMenuOpenSelection(
            forPanelId: panelId,
            liveAgentIndex: .shared
        )
    }

    func forkAgentConversationContextMenuOpenSelection(
        forPanelId panelId: UUID,
        liveAgentIndex: SharedLiveAgentIndex
    ) -> (
        availability: WorkspaceForkAgentConversationAvailability,
        snapshot: SessionRestorableAgentSnapshot?,
        validationFallbackSnapshot: SessionRestorableAgentSnapshot?
    ) {
        guard surfaceOwnershipTarget(for: panelId)?.panel is TerminalPanel else {
            return (.notTerminalPanel, nil, nil)
        }

        let isRemoteContext = isRemoteTerminalContext(panelId)
        if !allowsAgentContinuation(forPanelId: panelId) {
            if let observation = liveAgentIndex.index?.entry(workspaceId: id, panelId: panelId) {
                reconcileCompletedRestoredAgent(panelId: panelId, observation: observation)
            }
            if !allowsAgentContinuation(forPanelId: panelId) {
                guard liveAgentIndex.prepareForkAvailabilityProbe(
                    workspaceId: id,
                    panelId: panelId,
                    isRemoteContext: isRemoteContext
                ) else {
                    return (.agentIndexRefreshing, nil, nil)
                }
                if let observation = liveAgentIndex.index?.entry(workspaceId: id, panelId: panelId) {
                    reconcileCompletedRestoredAgent(panelId: panelId, observation: observation)
                }
            }
            guard allowsAgentContinuation(forPanelId: panelId) else {
                return (.noAgentSnapshot, nil, nil)
            }
        }
        let restoredSnapshot = restoredAgentSnapshotForContinuation(panelId: panelId)
        let liveAvailabilitySnapshot = liveAgentIndex.snapshotForForkAvailability(
            workspaceId: id,
            panelId: panelId,
            isRemoteContext: isRemoteContext
        )
        let liveCandidateSnapshot = liveAgentIndex.snapshotForForkConversationCandidate(
            workspaceId: id,
            panelId: panelId
        )
        if liveAvailabilitySnapshot == nil, liveCandidateSnapshot != nil {
            if liveAgentIndex.forkSupportProbeRejected(
                workspaceId: id,
                panelId: panelId,
                isRemoteContext: isRemoteContext
            ) {
                return (.unsupported, nil, nil)
            }
            guard liveAgentIndex.prepareForkAvailabilityProbe(
                workspaceId: id,
                panelId: panelId,
                isRemoteContext: isRemoteContext
            ) else {
                return (.agentIndexRefreshing, nil, nil)
            }
            return (.agentIndexRefreshing, nil, nil)
        }
        if let snapshotSource = AgentConversationForkSupport.availabilitySnapshotSource(
            liveIndexSnapshot: liveAvailabilitySnapshot,
            fallbackSnapshot: restoredSnapshot,
            isRemoteTerminal: isRemoteContext
        ) {
            switch AgentConversationForkSupport.snapshotAvailability(
                snapshotSource.snapshot,
                isRemoteTerminal: isRemoteContext
            ) {
            case .supportedWithoutProbe:
                return (.available, snapshotSource.snapshot, nil)
            case .unsupported:
                return (.unsupported, nil, nil)
            case .requiresProbe:
                guard liveAgentIndex.prepareForkAvailabilityProbe(
                    workspaceId: id,
                    panelId: panelId,
                    isRemoteContext: isRemoteContext,
                    fallbackSnapshot: snapshotSource.validationFallbackSnapshot
                ) else {
                    return (
                        .agentIndexRefreshing,
                        nil,
                        snapshotSource.validationFallbackSnapshot
                    )
                }
                if liveAgentIndex.forkSupportProbeAccepted(
                    workspaceId: id,
                    panelId: panelId,
                    isRemoteContext: isRemoteContext,
                    fallbackSnapshot: snapshotSource.validationFallbackSnapshot
                ) {
                    return (
                        .available,
                        snapshotSource.snapshot,
                        snapshotSource.validationFallbackSnapshot
                    )
                }
                if liveAgentIndex.forkSupportProbeRejected(
                    workspaceId: id,
                    panelId: panelId,
                    isRemoteContext: isRemoteContext,
                    fallbackSnapshot: snapshotSource.validationFallbackSnapshot
                ) {
                    return (.unsupported, nil, nil)
                }
                return (
                    .agentIndexRefreshing,
                    nil,
                    snapshotSource.validationFallbackSnapshot
                )
            }
        }

        guard liveAgentIndex.prepareForkAvailabilityProbe(
            workspaceId: id,
            panelId: panelId,
            isRemoteContext: isRemoteTerminalContext(panelId)
        ) else {
            return (.agentIndexRefreshing, nil, nil)
        }
        guard let verifiedSnapshot = liveAgentIndex.snapshotForForkAvailability(
            workspaceId: id,
            panelId: panelId,
            isRemoteContext: isRemoteTerminalContext(panelId)
        ) else {
            if liveAgentIndex.forkSupportProbeRejected(
                workspaceId: id,
                panelId: panelId,
                isRemoteContext: isRemoteTerminalContext(panelId)
            ) {
                return (.unsupported, nil, nil)
            }
            return (.noAgentSnapshot, nil, nil)
        }
        if let observation = liveAgentIndex.index?.entry(workspaceId: id, panelId: panelId) {
            reconcileCompletedRestoredAgent(panelId: panelId, observation: observation)
        }
        guard allowsAgentContinuation(forPanelId: panelId) else {
            return (.noAgentSnapshot, nil, nil)
        }

        switch AgentConversationForkSupport.snapshotAvailability(
            verifiedSnapshot,
            isRemoteTerminal: isRemoteTerminalContext(panelId)
        ) {
        case .supportedWithoutProbe, .requiresProbe:
            return (.available, verifiedSnapshot, nil)
        case .unsupported:
            return (.unsupported, nil, nil)
        }
    }

    private func forkAgentConversationContextMenuCandidateSnapshot(
        forPanelId panelId: UUID
    ) -> SessionRestorableAgentSnapshot? {
        guard allowsAgentContinuation(forPanelId: panelId) else { return nil }
        if let snapshot = SharedLiveAgentIndex.shared.snapshotForForkConversationCandidate(
            workspaceId: id,
            panelId: panelId
        ) {
            if let observation = SharedLiveAgentIndex.shared.index?.entry(
                workspaceId: id,
                panelId: panelId
            ) {
                reconcileCompletedRestoredAgent(panelId: panelId, observation: observation)
            }
            return snapshot
        }
        if let snapshot = restoredAgentSnapshotForContinuation(panelId: panelId) {
            return snapshot
        }
        if let observation = SharedLiveAgentIndex.shared.index?.entry(workspaceId: id, panelId: panelId) {
            reconcileCompletedRestoredAgent(panelId: panelId, observation: observation)
        }
        return nil
    }
}
