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

    func setAgentLifecycle(
        key: String,
        panelId: UUID?,
        lifecycle: AgentHibernationLifecycleState,
        sessionID: String? = nil,
        startsNewOccupant: Bool = false,
        expectedPIDKey: String? = nil,
        expectedPID: Int32? = nil,
        expectedPIDStartSeconds: Int64? = nil,
        expectedPIDStartMicroseconds: Int64? = nil
    ) {
        switch self {
        case .workspace(let workspace):
            workspace.setAgentLifecycle(
                key: key,
                panelId: panelId,
                lifecycle: lifecycle,
                sessionID: sessionID,
                startsNewOccupant: startsNewOccupant,
                expectedPIDKey: expectedPIDKey,
                expectedPID: expectedPID,
                expectedPIDStartSeconds: expectedPIDStartSeconds,
                expectedPIDStartMicroseconds: expectedPIDStartMicroseconds
            )
        case .dock(let dock):
            guard let panelId else { return }
            dock.setAgentLifecycle(
                key: key,
                panelId: panelId,
                lifecycle: lifecycle,
                sessionID: sessionID,
                startsNewOccupant: startsNewOccupant,
                expectedPIDKey: expectedPIDKey,
                expectedPID: expectedPID,
                expectedPIDStartSeconds: expectedPIDStartSeconds,
                expectedPIDStartMicroseconds: expectedPIDStartMicroseconds
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
    ) {
        switch self {
        case .workspace(let workspace):
            workspace.clearAgentPID(
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
            guard let panelId else { return }
            dock.clearAgentPID(
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
}
