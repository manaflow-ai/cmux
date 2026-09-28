import CmuxAgentChat
import CmuxMobileHost
import Foundation

/// One live agent pane with what it is doing and whether a restart can interrupt it.
struct AgentActivitySnapshot: Sendable {
    var workspaceID: UUID
    /// The workspace panel hosting the agent. Equal to ``surfaceID`` for
    /// ordinary terminals; kept separate so consumers need not assume that.
    var panelID: UUID
    /// The terminal surface the agent's hooks report (`CMUX_SURFACE_ID`).
    var surfaceID: UUID
    /// The split pane holding the panel, when it is in the split tree.
    var paneID: UUID?
    var name: String?
    var agentKind: String
    var sessionID: String
    var pid: Int?
    var placement: AgentPanePlacement
    var activity: AgentActivity
    var assessment: ResumeSafetyAssessment

    var survivesAppRelaunch: Bool { placement.survivesAppRelaunch }
}

/// Builds ``AgentActivitySnapshot``s from state the app already owns: the agent
/// session registry, hook turn facts, the Feed's decision overlay and, for local
/// panes, one bounded process census. Reading never refreshes or mutates anything.
@MainActor
struct AgentActivityIndex {
    /// How old a shared process census may be.
    nonisolated static let processCensusMaximumAge: TimeInterval = 2

    private let agentRecords: @MainActor () -> [AgentChatSessionRecord]?
    private let workspaceOwners: @MainActor (Set<UUID>) -> [UUID: Workspace]
    private let hookActivity: AgentHookActivityTracker
    private let processCensus: @Sendable () async -> CmuxTopProcessSnapshot

    init(
        agentRecords: @escaping @MainActor () -> [AgentChatSessionRecord]?,
        workspaceOwners: @escaping @MainActor (Set<UUID>) -> [UUID: Workspace],
        hookActivity: AgentHookActivityTracker = .shared,
        processCensus: @escaping @Sendable () async -> CmuxTopProcessSnapshot = {
            await CmuxTopProcessSnapshot.captureCached(
                includeCMUXScope: false,
                includeResources: false,
                maximumAge: AgentActivityIndex.processCensusMaximumAge
            )
        }
    ) {
        self.agentRecords = agentRecords
        self.workspaceOwners = workspaceOwners
        self.hookActivity = hookActivity
        self.processCensus = processCensus
    }

    /// One entry per live agent pane, most recently active first.
    func snapshot() async -> [AgentActivitySnapshot] {
        let panes = capture()
        let probes = panes.enumerated().compactMap { index, pane -> ForegroundProbe? in
            guard pane.placement == .local, let pid = pane.pid, pid > 0 else { return nil }
            return ForegroundProbe(index: index, agentPID: pid, notBefore: pane.evidence.hooks?.turnStartedAt)
        }
        let commands = probes.isEmpty ? [:] : await Self.foregroundCommands(probes, census: processCensus)
        return panes.enumerated().map { index, pane in
            var evidence = pane.evidence
            evidence.foregroundCommand = commands[index]
            let result = AgentActivityClassifier.classify(evidence.signals)
            return AgentActivitySnapshot(
                workspaceID: pane.workspaceID, panelID: pane.panelID, surfaceID: pane.panelID,
                paneID: pane.paneID, name: pane.name, agentKind: pane.agentKind, sessionID: pane.sessionID,
                pid: pane.pid, placement: pane.placement,
                activity: result.activity, assessment: result.safety
            )
        }
    }

    private struct Pane {
        var workspaceID: UUID
        var panelID: UUID
        var paneID: UUID?
        var name: String?
        var agentKind: String
        var sessionID: String
        var pid: Int?
        var placement: AgentPanePlacement
        var evidence: AgentActivityEvidence
    }

    private struct ForegroundProbe: Sendable {
        var index: Int
        var agentPID: Int
        var notBefore: Date?
    }

    /// Joins registry records to live panels in one main-actor turn.
    private func capture() -> [Pane] {
        guard let records = agentRecords() else { return [] }
        var bound: [(record: AgentChatSessionRecord, workspaceID: UUID, panelID: UUID)] = []
        var seenPanels: Set<UUID> = []
        // Records arrive most recent first; the newest live session owns its pane.
        for record in records {
            if case .ended = record.state { continue }
            guard let rawWorkspace = record.workspaceID, let workspaceID = UUID(uuidString: rawWorkspace),
                  let rawSurface = record.surfaceID, let panelID = UUID(uuidString: rawSurface),
                  seenPanels.insert(panelID).inserted else { continue }
            bound.append((record, workspaceID, panelID))
        }
        let owners = workspaceOwners(Set(bound.map(\.workspaceID)))
        return bound.compactMap { record, workspaceID, panelID in
            guard let workspace = owners[workspaceID] else { return nil }
            let dock = workspace.panels[panelID] == nil ? workspace._dockSplit : nil
            guard let panel = workspace.panels[panelID] ?? dock?.panels[panelID] else { return nil }
            let lifecycles = dock?.agentRuntimeByPanelId[panelID]?.agentLifecycleStates
                ?? workspace.agentLifecycleStatesByPanelId[panelID] ?? [:]
            let feedKey = FeedCoordinator.attentionStatusKey(forSource: record.agentKind.sourceName)
            let placement = Self.placement(
                workspace: workspace,
                panel: panel,
                dockRemote: dock?.terminalLinkIsRemoteTerminal(panelID) ?? false
            )
            let hooks = hookActivity.state(
                surfaceID: panelID,
                sessionIDs: [record.sessionID] + [record.hookStoreSessionID].compactMap { $0 }
            )
            let paneID = dock == nil ? workspace.paneId(forPanelId: panelID)?.id : dock?.paneId(forPanelId: panelID)?.id
            let title = dock == nil ? workspace.panelTitle(panelId: panelID) : nil
            return Pane(
                workspaceID: workspaceID, panelID: panelID, paneID: paneID,
                name: Self.nonEmpty(title) ?? Self.nonEmpty(record.title),
                agentKind: record.agentKind.sourceName, sessionID: record.sessionID,
                pid: record.pid, placement: placement,
                evidence: AgentActivityEvidence(
                    registryState: record.state,
                    registryHasHookLifecycleState: record.hasHookLifecycleState,
                    registryLastActivityAt: record.lastActivityAt,
                    hooks: hooks,
                    feedDecisionPending: lifecycles[feedKey] == .needsInput
                )
            )
        }
    }

    private static func placement(workspace: Workspace, panel: any Panel, dockRemote: Bool) -> AgentPanePlacement {
        if (panel as? TerminalPanel)?.cloudAttachment != nil
            || workspace.remoteConfiguration?.managedCloudVMID != nil {
            return .cloud
        }
        if let configuration = workspace.remoteConfiguration {
            return .ssh(host: configuration.destination)
        }
        if workspace.isRemoteTmuxMirror || dockRemote {
            return .ssh(host: nil)
        }
        return .local
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    /// Reads one census off the main actor. An unavailable census leaves every
    /// command unknown rather than proving none runs.
    private nonisolated static func foregroundCommands(
        _ probes: [ForegroundProbe],
        census: @Sendable () async -> CmuxTopProcessSnapshot
    ) async -> [Int: String] {
        let snapshot = await census()
        guard snapshot.captureIsAvailable else { return [:] }
        var commands: [Int: String] = [:]
        for probe in probes {
            var processes: [Int: AgentForegroundCommand.Process] = [:]
            for pid in snapshot.descendantPIDs(rootPID: probe.agentPID, includeRoot: true) {
                guard let process = snapshot.process(pid: pid) else { continue }
                processes[pid] = AgentForegroundCommand.Process(
                    pid: pid,
                    parentPID: process.parentPID,
                    name: process.name,
                    isTerminalForeground: process.isTerminalForegroundProcessGroup,
                    startedAt: process.processIdentity.map {
                        Date(timeIntervalSince1970: TimeInterval($0.startSeconds) + TimeInterval($0.startMicroseconds) / 1_000_000)
                    }
                )
            }
            guard let pid = AgentForegroundCommand.commandPID(
                agentPID: probe.agentPID, processes: processes, notBefore: probe.notBefore
            ), let process = snapshot.process(pid: pid),
                  let arguments = CmuxTopProcessSnapshot.processArgumentsAndEnvironment(for: process)?.arguments else {
                continue
            }
            commands[probe.index] = AgentForegroundCommand.describe(arguments: arguments)
        }
        return commands
    }
}
