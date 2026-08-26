import CmuxControlSocket
import CmuxSidebar
import Darwin
import Foundation

/// The current owner of panel-scoped sidebar and agent runtime mutations.
@MainActor
enum ControlSidebarPanelOwner {
    case workspace(Workspace)
    case dock(DockSplitStore)

    var id: UUID {
        switch self {
        case .workspace(let workspace): workspace.id
        case .dock(let dock): dock.workspaceId
        }
    }

    func agentLifecycleRegistryScope(panelId: UUID?) -> ControlSidebarAgentLifecycleRegistryScope {
        switch self {
        case .workspace(let workspace):
            let candidates = [
                panelId.flatMap { workspace.effectivePanelDirectory(panelId: $0) },
                workspace.focusedPanelId.flatMap { workspace.effectivePanelDirectory(panelId: $0) },
                workspace.usesRemoteDirectoryProvenance
                    ? workspace.presentedCurrentDirectory
                    : workspace.currentDirectory,
            ]
            return .project(candidates.compactMap(Self.normalizedOptionValue).first)
        case .dock(let dock):
            guard let panelId else { return .project(nil) }
            return dock.agentLifecycleRegistryScope(for: panelId)
        }
    }

    func statusEntry(key: String, panelId: UUID?) -> SidebarStatusEntry? {
        switch self {
        case .workspace(let workspace): workspace.statusEntries[key]
        case .dock(let dock):
            panelId.flatMap { dock.agentRuntimeStatusEntry(key: key, panelId: $0) }
        }
    }

    func setStatusEntry(_ entry: SidebarStatusEntry, key: String, panelId: UUID?) {
        switch self {
        case .workspace(let workspace): workspace.statusEntries[key] = entry
        case .dock(let dock):
            guard let panelId else { return }
            dock.setAgentRuntimeStatusEntry(entry, key: key, panelId: panelId)
        }
    }

    func clearStatusEntry(key: String, panelId: UUID?) {
        switch self {
        case .workspace(let workspace):
            workspace.statusEntries.removeValue(forKey: key)
        case .dock(let dock):
            guard let panelId else { return }
            dock.clearAgentRuntimeStatusEntry(key: key, panelId: panelId)
        }
    }

    /// Revalidates the occupant at the final main-actor mutation boundary.
    /// The exact recorded generation or durable session must still own this
    /// panel. Process liveness is established when ownership is claimed, not
    /// here: a valid completion hook may outlive its process while queued.
    func acceptsAgentMutationGuard(
        _ guardValue: ControlSidebarAgentMutationGuard,
        panelId: UUID?
    ) -> Bool {
        guard let panelId else { return false }
        if case .session(_, let sessionID) = guardValue,
           !acceptsRelayLifecycleGeneration(sessionID, panelId: panelId) {
            return false
        }
        switch (self, guardValue) {
        case let (.workspace(workspace), .session(statusKey, sessionID)):
            return workspace.agentLifecycleRecordsByPanelId[panelId]?[statusKey]?.sessionID
                == sessionID
        case let (.workspace(workspace), .process(statusKey, pidKey, pid, seconds, microseconds)):
            let identity = AgentPIDProcessIdentity(
                pid: pid,
                startSeconds: seconds,
                startMicroseconds: microseconds
            )
            return workspace.agentStatusKey(forAgentPIDKey: pidKey) == statusKey
                && workspace.agentPIDPanelIdsByKey[pidKey] == panelId
                && workspace.agentPIDs[pidKey] == pid
                && workspace.agentPIDProcessIdentitiesByKey[pidKey] == identity
        case let (.dock(dock), .session(statusKey, sessionID)):
            guard let runtime = dock.agentRuntimeByPanelId[panelId] else { return false }
            return runtime.agentLifecycleSessionIDs[statusKey] == sessionID
        case let (.dock(dock), .process(statusKey, pidKey, pid, seconds, microseconds)):
            guard let runtime = dock.agentRuntimeByPanelId[panelId] else { return false }
            let identity = AgentPIDProcessIdentity(
                pid: pid,
                startSeconds: seconds,
                startMicroseconds: microseconds
            )
            return DockSplitStore.agentStatusKey(forAgentPIDKey: pidKey, runtime: runtime) == statusKey
                && runtime.agentPIDKeys.contains(pidKey)
                && runtime.agentPIDs[pidKey] == pid
                && runtime.agentPIDProcessIdentities[pidKey] == identity
        }
    }

    @discardableResult
    func recordAgentPID(
        key: String,
        pid: pid_t,
        panelId: UUID?,
        expectedLifecycleSessionID: String? = nil,
        expectedPIDStartSeconds: Int64? = nil,
        expectedPIDStartMicroseconds: Int64? = nil
    ) -> Bool {
        switch self {
        case .workspace(let workspace):
            return workspace.recordAgentPID(
                key: key,
                pid: pid,
                panelId: panelId,
                expectedLifecycleSessionID: expectedLifecycleSessionID,
                expectedPIDStartSeconds: expectedPIDStartSeconds,
                expectedPIDStartMicroseconds: expectedPIDStartMicroseconds
            )
        case .dock(let dock):
            guard let panelId else { return false }
            return dock.recordAgentPID(
                key: key,
                pid: pid,
                panelId: panelId,
                expectedLifecycleSessionID: expectedLifecycleSessionID,
                expectedPIDStartSeconds: expectedPIDStartSeconds,
                expectedPIDStartMicroseconds: expectedPIDStartMicroseconds
            )
        }
    }

    @discardableResult
    func setAgentLifecycle(
        key: String,
        panelId: UUID?,
        lifecycle: AgentHibernationLifecycleState,
        sessionID: String? = nil,
        startsNewOccupant: Bool = false,
        expectedPIDKey: String? = nil,
        expectedPID: Int32? = nil,
        expectedPIDStartSeconds: Int64? = nil,
        expectedPIDStartMicroseconds: Int64? = nil,
        requireExistingOwner: Bool = false,
        apply: Bool = true
    ) -> Bool {
        if let sessionID,
           !acceptsRelayLifecycleGeneration(sessionID, panelId: panelId) {
            return false
        }
        if startsNewOccupant,
           let sessionID,
           !relayLifecycleReplacementIsCausallyNewer(
               key: key,
               incomingSessionID: sessionID,
               panelId: panelId
           ) {
            return false
        }
        switch self {
        case .workspace(let workspace):
            return workspace.setAgentLifecycle(
                key: key,
                panelId: panelId,
                lifecycle: lifecycle,
                sessionID: sessionID,
                startsNewOccupant: startsNewOccupant,
                expectedPIDKey: expectedPIDKey,
                expectedPID: expectedPID,
                expectedPIDStartSeconds: expectedPIDStartSeconds,
                expectedPIDStartMicroseconds: expectedPIDStartMicroseconds,
                requireExistingOwner: requireExistingOwner,
                apply: apply
            )
        case .dock(let dock):
            guard let panelId else { return false }
            return dock.setAgentLifecycle(
                key: key,
                panelId: panelId,
                lifecycle: lifecycle,
                sessionID: sessionID,
                startsNewOccupant: startsNewOccupant,
                expectedPIDKey: expectedPIDKey,
                expectedPID: expectedPID,
                expectedPIDStartSeconds: expectedPIDStartSeconds,
                expectedPIDStartMicroseconds: expectedPIDStartMicroseconds,
                requireExistingOwner: requireExistingOwner,
                apply: apply
            )
        }
    }

    func clearAgentPID(
        key: String,
        panelId: UUID?,
        clearStatus: Bool,
        expectedLifecycleSessionID: String? = nil,
        expectedPID: pid_t? = nil,
        expectedPIDStartSeconds: Int64? = nil,
        expectedPIDStartMicroseconds: Int64? = nil,
        requireOwnedKey: Bool = false
    ) -> Bool {
        if let expectedLifecycleSessionID,
           !acceptsRelayLifecycleGeneration(
               expectedLifecycleSessionID,
               panelId: panelId
           ) {
            return false
        }
        switch self {
        case .workspace(let workspace):
            return workspace.clearAgentPID(
                key: key,
                panelId: panelId,
                clearStatus: clearStatus,
                requireOwnedKey: requireOwnedKey,
                expectedLifecycleSessionID: expectedLifecycleSessionID,
                expectedPID: expectedPID,
                expectedPIDStartSeconds: expectedPIDStartSeconds,
                expectedPIDStartMicroseconds: expectedPIDStartMicroseconds
            )
        case .dock(let dock):
            guard let panelId else { return false }
            return dock.clearAgentPID(
                key: key,
                panelId: panelId,
                clearStatus: clearStatus,
                expectedLifecycleSessionID: expectedLifecycleSessionID,
                expectedPID: expectedPID,
                expectedPIDStartSeconds: expectedPIDStartSeconds,
                expectedPIDStartMicroseconds: expectedPIDStartMicroseconds,
                requireOwnedKey: requireOwnedKey
            )
        }
    }

    private static func normalizedOptionValue(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Validates the relay terminal/attempt generation encoded by the hook.
    private func acceptsRelayLifecycleGeneration(
        _ sessionID: String,
        panelId: UUID?
    ) -> Bool {
        guard let panelId,
              let generation = Self.relayLifecycleGeneration(sessionID) else {
            return !sessionID.contains("#relay#")
        }
        switch self {
        case .workspace(let workspace):
            return (workspace.panels[panelId] as? TerminalPanel)?
                .surface.terminalLifecycleId == generation.terminalLifecycleID
                && workspace.remoteTerminalAttemptIDsBySurfaceId[panelId]
                    == generation.attemptID
        case .dock(let dock):
            let transfer = dock.detachedSurfaceTransfersByPanelId[panelId]
            return transfer?.remoteTerminalLifecycleID == generation.terminalLifecycleID
                && transfer?.remoteTerminalAttemptID == generation.attemptID
        }
    }

    private static func relayLifecycleGeneration(
        _ sessionID: String
    ) -> (
        terminalLifecycleID: UUID,
        attemptID: UUID,
        pid: Int,
        startSeconds: Int64,
        startMicroseconds: Int64
    )? {
        let components = sessionID.components(separatedBy: "#relay#")
        guard components.count == 2, !components[0].isEmpty else { return nil }
        let generation = components[1].split(
            separator: "#",
            omittingEmptySubsequences: false
        )
        guard generation.count == 5,
              let terminalLifecycleID = UUID(uuidString: String(generation[0])),
              let attemptID = UUID(uuidString: String(generation[1])),
              let pid = Int(generation[2]),
              pid > 0,
              let startSeconds = Int64(generation[3]),
              startSeconds >= 0,
              let startMicroseconds = Int64(generation[4]),
              startMicroseconds >= 0,
              startMicroseconds < 1_000_000 else {
            return nil
        }
        return (
            terminalLifecycleID,
            attemptID,
            pid,
            startSeconds,
            startMicroseconds
        )
    }

    /// Within one relay attempt, only a strictly newer process may replace the owner.
    private func relayLifecycleReplacementIsCausallyNewer(
        key: String,
        incomingSessionID: String,
        panelId: UUID?
    ) -> Bool {
        guard let incoming = Self.relayLifecycleGeneration(incomingSessionID) else {
            return !incomingSessionID.contains("#relay#")
        }
        guard let panelId else { return false }
        let currentSessionID: String?
        switch self {
        case .workspace(let workspace):
            currentSessionID = workspace.agentLifecycleRecordsByPanelId[panelId]?[key]?
                .sessionID
        case .dock(let dock):
            currentSessionID = dock.agentRuntimeByPanelId[panelId]?
                .agentLifecycleSessionIDs[key]
        }
        guard let currentSessionID,
              currentSessionID != incomingSessionID,
              let current = Self.relayLifecycleGeneration(currentSessionID) else {
            return true
        }
        guard current.terminalLifecycleID == incoming.terminalLifecycleID,
              current.attemptID == incoming.attemptID else {
            return true
        }
        if current.startSeconds != incoming.startSeconds {
            return current.startSeconds < incoming.startSeconds
        }
        if current.startMicroseconds != incoming.startMicroseconds {
            return current.startMicroseconds < incoming.startMicroseconds
        }
        // OMP can mint a fresh session alias from the same live process. The
        // generation is identical in that case, so command order—not a birth
        // timestamp that cannot distinguish aliases—authorizes the rotation.
        return true
    }
}
