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

    /// Relay-backed hooks report process identifiers from the remote host.
    /// Those numeric PIDs must never be resolved, stored, or monitored against
    /// the Mac's local process table.
    func usesRemoteAgentProcessNamespace(panelId: UUID?) -> Bool {
        switch self {
        case .workspace(let workspace):
            return workspace.remoteConfiguration != nil
        case .dock(let dock):
            guard let panelId else { return false }
            return dock.detachedSurfaceTransfersByPanelId[panelId]?
                .isRemoteTerminal == true
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

    func agentLifecycleState(
        key: String,
        panelId: UUID
    ) -> AgentHibernationLifecycleState? {
        switch self {
        case .workspace(let workspace):
            workspace.agentLifecycleStatesByPanelId[panelId]?[key]
        case .dock(let dock):
            dock.agentRuntimeLifecycleState(key: key, panelId: panelId)
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

    func recordAgentPID(
        key: String,
        pid: pid_t,
        panelId: UUID?
    ) -> ControlSidebarAgentPIDRecordResult {
        recordAgentPID(
            key: key,
            pid: pid,
            panelId: panelId,
            acceptedProcessIdentity: AgentPIDProcessIdentity(pid: pid)
        )
    }

    /// Records only the exact process generation observed when the socket
    /// command was accepted. Rechecking here prevents a queued main-actor
    /// mutation from binding stale evidence to a recycled numeric PID.
    func recordAgentPID(
        key: String,
        pid: pid_t,
        panelId: UUID?,
        acceptedProcessIdentity: AgentPIDProcessIdentity?
    ) -> ControlSidebarAgentPIDRecordResult {
        if usesRemoteAgentProcessNamespace(panelId: panelId) {
            // Surface/workspace identity remains authoritative across a relay,
            // but the PID belongs to another kernel namespace. Accept the
            // command without binding it to an unrelated local generation.
            return .accepted(replacedOtherRuntime: false)
        }
        let statusKey = agentStatusKey(
            forAgentPIDKey: key,
            panelId: panelId
        )
        let isBuiltIn = AgentHibernationLifecycleStatusKeys(
            rawValue: statusKey
        ).isAllowed
        guard let acceptedProcessIdentity,
              AgentPIDProcessIdentity(pid: pid)
                == acceptedProcessIdentity else {
            switch self {
            case .workspace(let workspace):
                if isBuiltIn {
                    workspace.recordUnidentifiedAgentProcessExit(
                        key: statusKey,
                        panelId: panelId
                    )
                }
            case .dock(let dock):
                guard let panelId else { return .rejected }
                if isBuiltIn {
                    dock.recordUnidentifiedAgentProcessExit(
                        key: statusKey,
                        panelId: panelId
                    )
                }
            }
            return .rejected
        }
        switch self {
        case .workspace(let workspace):
            let result = workspace.recordAgentPIDResult(
                key: key,
                pid: pid,
                panelId: panelId,
                processIdentity: acceptedProcessIdentity
            )
            return result.accepted
                ? .accepted(
                    replacedOtherRuntime: result.replacedOtherRuntime
                )
                : .rejected
        case .dock(let dock):
            guard let panelId else { return .rejected }
            let result = dock.recordAgentPIDResult(
                key: key,
                pid: pid,
                panelId: panelId,
                processIdentity: acceptedProcessIdentity
            )
            return result.accepted
                ? .accepted(
                    replacedOtherRuntime: result.replacedOtherRuntime
                )
                : .rejected
        }
    }

    private func agentStatusKey(
        forAgentPIDKey key: String,
        panelId: UUID?
    ) -> String {
        if statusEntry(key: key, panelId: panelId) != nil {
            return key
        }
        guard let dotIndex = key.firstIndex(of: ".") else {
            return key
        }
        return String(key[..<dotIndex])
    }

    @discardableResult
    func setAgentLifecycle(
        key: String,
        panelId: UUID?,
        lifecycle: AgentHibernationLifecycleState,
        processGeneration: AgentPIDProcessIdentity? = nil
    ) -> Bool {
        let targetPanelId: UUID?
        let accepted: Bool
        switch self {
        case .workspace(let workspace):
            targetPanelId = panelId ?? workspace.focusedPanelId
            accepted = workspace.setAgentLifecycle(
                key: key,
                panelId: panelId,
                lifecycle: lifecycle,
                processGeneration: processGeneration
            )
        case .dock(let dock):
            guard let panelId else { return false }
            targetPanelId = panelId
            accepted = dock.setAgentLifecycle(
                key: key,
                panelId: panelId,
                lifecycle: lifecycle,
                processGeneration: processGeneration
            )
        }
        if accepted, let targetPanelId {
            FeedCoordinator.shared.reconcileObservedAgentAttention(
                workspaceId: id,
                panelId: targetPanelId,
                statusKey: key,
                lifecycle: lifecycle,
                processGeneration: processGeneration
            )
        }
        return accepted
    }

    @discardableResult
    func clearAgentLifecycle(
        key: String,
        panelId: UUID?
    ) -> Bool {
        switch self {
        case .workspace(let workspace):
            return workspace.clearAgentLifecycle(
                key: key,
                panelId: panelId
            )
        case .dock(let dock):
            guard let panelId else { return false }
            return dock.clearAgentLifecycle(
                key: key,
                panelId: panelId
            )
        }
    }

    func hasLiveAgentProcess(
        statusKey: String,
        panelId: UUID?,
        matching generation: AgentPIDProcessIdentity? = nil
    ) -> Bool {
        switch self {
        case .workspace(let workspace):
            guard let panelId = panelId ?? workspace.focusedPanelId else {
                return false
            }
            return workspace.hasLiveAgentProcess(
                statusKey: statusKey,
                panelId: panelId,
                matching: generation
            )
        case .dock(let dock):
            guard let panelId else { return false }
            return dock.hasLiveAgentProcess(
                statusKey: statusKey,
                panelId: panelId,
                matching: generation
            )
        }
    }

    func beginAgentFeedAttention(
        key: String,
        panelId: UUID,
        processGeneration: AgentPIDProcessIdentity? = nil
    ) -> AgentFeedAttentionToken? {
        switch self {
        case .workspace(let workspace):
            return workspace.beginAgentFeedAttention(
                key: key,
                panelId: panelId,
                processGeneration: processGeneration
            )
        case .dock(let dock):
            return dock.beginAgentFeedAttention(
                key: key,
                panelId: panelId,
                processGeneration: processGeneration
            )
        }
    }

    @discardableResult
    func recordAgentProcessExit(
        key: String,
        panelId: UUID,
        generation: AgentPIDProcessIdentity
    ) -> Bool {
        let recorded: Bool
        let workspaceId: UUID
        switch self {
        case .workspace(let workspace):
            workspaceId = workspace.id
            recorded = workspace.sidebarAgentRuntimeObservation
                .recordAgentProcessExit(
                    key: key,
                    panelId: panelId,
                    generation: generation
                )
        case .dock(let dock):
            workspaceId = dock.workspaceId
            recorded = dock.recordAgentProcessExit(
                key: key,
                panelId: panelId,
                generation: generation
            )
        }
        guard recorded else { return false }
        recordAgentProcessExitEffects(
            workspaceId: workspaceId,
            panelId: panelId,
            statusKey: key,
            processGeneration: generation
        )
        return true
    }

    private func recordAgentProcessExitEffects(
        workspaceId: UUID,
        panelId: UUID,
        statusKey: String,
        processGeneration: AgentPIDProcessIdentity
    ) {
        AgentHibernationController.shared.recordAgentLifecycleChange(
            workspaceId: workspaceId,
            panelId: panelId
        )
        FeedCoordinator.shared.retireObservedAgentAttentionForProcessExit(
            workspaceId: workspaceId,
            panelId: panelId,
            statusKey: statusKey,
            processGeneration: processGeneration
        )
    }

    @discardableResult
    func endAgentFeedAttention(
        key: String,
        panelId: UUID,
        token: AgentFeedAttentionToken
    ) -> Bool {
        switch self {
        case .workspace(let workspace):
            return workspace.endAgentFeedAttention(
                key: key,
                panelId: panelId,
                token: token
            )
        case .dock(let dock):
            return dock.endAgentFeedAttention(
                key: key,
                panelId: panelId,
                token: token
            )
        }
    }

    @discardableResult
    func clearAgentLifecycle(key: String, panelId: UUID?) -> Bool {
        switch self {
        case .workspace(let workspace):
            return workspace.clearAgentLifecycle(key: key, panelId: panelId)
        case .dock(let dock):
            guard let panelId else { return false }
            return dock.clearAgentLifecycle(key: key, panelId: panelId)
        }
    }

    func clearAgentPID(
        key: String,
        panelId: UUID?,
        clearStatus: Bool,
        requireOwnedKey: Bool = false
    ) {
        switch self {
        case .workspace(let workspace):
            workspace.clearAgentPID(
                key: key,
                panelId: panelId,
                clearStatus: clearStatus,
                requireOwnedKey: requireOwnedKey
            )
        case .dock(let dock):
            guard let panelId else { return }
            dock.clearAgentPID(
                key: key,
                panelId: panelId,
                clearStatus: clearStatus,
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
