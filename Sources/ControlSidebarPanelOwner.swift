import CMUXAgentLaunch
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

    /// Validates an exact-session hook mutation against the panel's current
    /// binding, falling back to recorded PID ownership for integrations that
    /// do not publish a resume binding. A missing runtime key preserves the
    /// legacy command contract for older hooks.
    func allowsAgentRuntimeMutation(
        statusKey: String,
        runtimeKey: String?,
        runtimeGeneration: TimeInterval? = nil,
        panelId: UUID?,
        allowsRetiredCleanup: Bool = false
    ) -> Bool {
        guard let runtimeKey else { return true }
        guard let panelId,
              let sessionKey = AgentRuntimeSessionKey(rawValue: runtimeKey),
              sessionKey.statusKey == statusKey else {
            return false
        }

        let binding: SurfaceResumeBindingSnapshot?
        let lifecycle: RestoredAgentLifecycleCoordinator
        switch self {
        case .workspace(let workspace):
            binding = workspace.authoritativeAgentRuntimeBinding(panelId: panelId)
            lifecycle = workspace.restoredAgentLifecycle
        case .dock(let dock):
            binding = dock.authoritativeAgentRuntimeBinding(panelId: panelId)
            lifecycle = dock.restoredAgentLifecycle
        }

        if allowsRetiredCleanup {
            return lifecycle.consumeAgentRuntimeCleanupAuthority(
                sessionKey: sessionKey,
                generation: runtimeGeneration,
                panelId: panelId
            )
        }
        if binding?.agentRuntimeStatusKey != nil,
           binding?.matchesExactAgentRuntimeKey(runtimeKey) != true {
            return false
        }
        return lifecycle.allowsAgentRuntimeMutation(
            sessionKey: sessionKey,
            generation: runtimeGeneration,
            panelId: panelId
        )
    }

    /// Authorizes panel-scoped notification teardown without consuming runtime
    /// authority. This is deliberately separate from ordinary delivery and
    /// status mutation authorization because SessionEnd retires the runtime
    /// before its queued notification clear reaches the main actor.
    func allowsAgentNotificationCleanup(
        statusKey: String,
        runtimeKey: String?,
        runtimeGeneration: TimeInterval? = nil,
        panelId: UUID?
    ) -> Bool {
        guard let runtimeKey else { return true }
        guard let panelId,
              let sessionKey = AgentRuntimeSessionKey(rawValue: runtimeKey),
              sessionKey.statusKey == statusKey else {
            return false
        }

        let lifecycle: RestoredAgentLifecycleCoordinator
        switch self {
        case .workspace(let workspace):
            lifecycle = workspace.restoredAgentLifecycle
        case .dock(let dock):
            lifecycle = dock.restoredAgentLifecycle
        }
        return lifecycle.allowsAgentRuntimeNotificationCleanup(
            sessionKey: sessionKey,
            generation: runtimeGeneration,
            panelId: panelId
        )
    }

    /// Establishes exact-session authority only from a binding-compatible PID
    /// publication. Ordinary status/lifecycle/notification mutations use the
    /// read-only authorization path above.
    private func establishesAgentRuntimeAuthority(
        statusKey: String,
        runtimeKey: String,
        runtimeGeneration: TimeInterval?,
        panelId: UUID?
    ) -> Bool {
        guard let panelId,
              let sessionKey = AgentRuntimeSessionKey(rawValue: runtimeKey),
              sessionKey.statusKey == statusKey else {
            return false
        }

        let binding: SurfaceResumeBindingSnapshot?
        let lifecycle: RestoredAgentLifecycleCoordinator
        switch self {
        case .workspace(let workspace):
            binding = workspace.authoritativeAgentRuntimeBinding(panelId: panelId)
            lifecycle = workspace.restoredAgentLifecycle
        case .dock(let dock):
            binding = dock.authoritativeAgentRuntimeBinding(panelId: panelId)
            lifecycle = dock.restoredAgentLifecycle
        }
        if binding?.agentRuntimeStatusKey != nil,
           binding?.matchesExactAgentRuntimeKey(runtimeKey) != true {
            return false
        }
        return lifecycle.establishAgentRuntimeAuthority(
            sessionKey: sessionKey,
            generation: runtimeGeneration,
            panelId: panelId
        )
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

    @discardableResult
    func recordAgentPID(
        key: String,
        pid: pid_t,
        panelId: UUID?,
        runtimeKey: String? = nil,
        runtimeGeneration: TimeInterval? = nil
    ) -> Bool {
        if let runtimeKey {
            guard let sessionKey = AgentRuntimeSessionKey(rawValue: runtimeKey),
                  sessionKey.compatibleRawValues.contains(key),
                  establishesAgentRuntimeAuthority(
                      statusKey: sessionKey.statusKey,
                      runtimeKey: runtimeKey,
                      runtimeGeneration: runtimeGeneration,
                      panelId: panelId
                  ) else {
                return false
            }
        }
        switch self {
        case .workspace(let workspace):
            return workspace.recordAgentPID(key: key, pid: pid, panelId: panelId)
        case .dock(let dock):
            guard let panelId else { return false }
            return dock.recordAgentPID(key: key, pid: pid, panelId: panelId)
        }
    }

    func setAgentLifecycle(
        key: String,
        panelId: UUID?,
        lifecycle: AgentHibernationLifecycleState,
        runtimeKey: String? = nil,
        runtimeGeneration: TimeInterval? = nil
    ) {
        guard allowsAgentRuntimeMutation(
            statusKey: key,
            runtimeKey: runtimeKey,
            runtimeGeneration: runtimeGeneration,
            panelId: panelId
        ) else {
            return
        }
        switch self {
        case .workspace(let workspace):
            workspace.setAgentLifecycle(key: key, panelId: panelId, lifecycle: lifecycle)
        case .dock(let dock):
            guard let panelId else { return }
            dock.setAgentLifecycle(key: key, panelId: panelId, lifecycle: lifecycle)
        }
    }

    func clearAgentPID(
        key: String,
        panelId: UUID?,
        clearStatus: Bool,
        requireOwnedKey: Bool = false,
        runtimeKey: String? = nil,
        runtimeGeneration: TimeInterval? = nil
    ) {
        if requireOwnedKey, !ownsAgentPIDKey(key, panelId: panelId) {
            return
        }
        if let runtimeKey {
            guard let sessionKey = AgentRuntimeSessionKey(rawValue: runtimeKey),
                  key == sessionKey.statusKey
                    || sessionKey.compatibleRawValues.contains(key),
                  allowsAgentRuntimeMutation(
                      statusKey: sessionKey.statusKey,
                      runtimeKey: runtimeKey,
                      runtimeGeneration: runtimeGeneration,
                      panelId: panelId,
                      allowsRetiredCleanup: true
                  ) else {
                return
            }
        }
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

    private func ownsAgentPIDKey(_ key: String, panelId: UUID?) -> Bool {
        switch self {
        case .workspace(let workspace):
            guard let ownedPanelId = workspace.agentPIDPanelIdsByKey[key] else {
                return false
            }
            return panelId == nil || panelId == ownedPanelId
        case .dock(let dock):
            guard let panelId else { return false }
            return dock.agentRuntimeByPanelId[panelId]?.agentPIDKeys.contains(key) == true
        }
    }

    private static func normalizedOptionValue(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
