import AppKit
import CMUXAgentLaunch
import CmuxControlSocket
import Foundation

@MainActor
enum ControlSurfaceResumeTarget {
    case workspace(tabManager: TabManager, workspace: Workspace, surfaceID: UUID)
    case dock(tabManager: TabManager, dock: DockSplitStore, surfaceID: UUID)

    var tabManager: TabManager {
        switch self {
        case .workspace(let tabManager, _, _), .dock(let tabManager, _, _): tabManager
        }
    }

    var surfaceID: UUID {
        switch self {
        case .workspace(_, _, let surfaceID), .dock(_, _, let surfaceID): surfaceID
        }
    }

    var workspaceID: UUID {
        switch self {
        case .workspace(_, let workspace, _): workspace.id
        case .dock(_, let dock, _): dock.workspaceId
        }
    }

    var paneID: UUID? {
        switch self {
        case .workspace(_, let workspace, let surfaceID):
            workspace.paneId(forPanelId: surfaceID)?.id
        case .dock(_, let dock, let surfaceID):
            dock.paneId(forPanelId: surfaceID)?.id
        }
    }

    var binding: SurfaceResumeBindingSnapshot? {
        switch self {
        case .workspace(_, let workspace, let surfaceID):
            workspace.surfaceResumeBinding(panelId: surfaceID)
        case .dock(_, let dock, let surfaceID):
            dock.surfaceResumeBinding(panelId: surfaceID)
        }
    }

    var restorableAgent: SessionRestorableAgentSnapshot? {
        switch self {
        case .workspace(_, let workspace, let surfaceID):
            workspace.restoredAgentSnapshotsByPanelId[surfaceID]
        case .dock(_, let dock, let surfaceID):
            dock.restoredAgentLifecycle.snapshotsByPanelId[surfaceID]
        }
    }

    var restoredResumeWorkingDirectory: String? {
        switch self {
        case .workspace(_, let workspace, let surfaceID):
            workspace.restoredResumeSessionWorkingDirectoriesByPanelId[surfaceID]
        case .dock(_, let dock, let surfaceID):
            dock.restoredResumeSessionWorkingDirectoriesByPanelId[surfaceID]
        }
    }

    @discardableResult
    func setBinding(_ binding: SurfaceResumeBindingSnapshot) -> Bool {
        switch self {
        case .workspace(_, let workspace, let surfaceID):
            workspace.setSurfaceResumeBinding(binding, panelId: surfaceID)
        case .dock(_, let dock, let surfaceID):
            dock.setSurfaceResumeBinding(binding, panelId: surfaceID)
        }
    }

    /// Atomically claims the current binding generation for a CLI restore.
    func claimBinding(
        expectedCheckpointID: String,
        expectedSource: String,
        expectedUpdatedAt: TimeInterval
    ) -> Bool {
        switch self {
        case .workspace(_, let workspace, let surfaceID):
            workspace.claimSurfaceResumeBinding(
                panelId: surfaceID,
                expectedCheckpointID: expectedCheckpointID,
                expectedSource: expectedSource,
                expectedUpdatedAt: expectedUpdatedAt
            )
        case .dock(_, let dock, let surfaceID):
            dock.claimSurfaceResumeBinding(
                panelId: surfaceID,
                expectedCheckpointID: expectedCheckpointID,
                expectedSource: expectedSource,
                expectedUpdatedAt: expectedUpdatedAt
            )
        }
    }

    func bindingForClear(
        expectedSource: String?,
        agentSessionEnded: Bool
    ) -> SurfaceResumeBindingSnapshot? {
        switch self {
        case .workspace:
            return binding
        case .dock(_, let dock, let surfaceID):
            if expectedSource == "agent-hook" || agentSessionEnded {
                return dock.managedAgentResumeBinding(panelId: surfaceID)
            }
            return binding
        }
    }

    func clearBinding(
        _ binding: SurfaceResumeBindingSnapshot?,
        agentSessionEnded: Bool
    ) {
        switch self {
        case .workspace(_, let workspace, let surfaceID):
            _ = workspace.clearSurfaceResumeBinding(
                panelId: surfaceID,
                agentSessionEnded: agentSessionEnded
            )
        case .dock(_, let dock, let surfaceID):
            _ = dock.clearSurfaceResumeBinding(
                panelId: surfaceID,
                binding: binding,
                agentSessionEnded: agentSessionEnded
            )
        }
    }

    func registeredBinding(
        _ binding: SurfaceResumeBindingSnapshot,
        inputs: ControlSurfaceResumeSetInputs
    ) -> SurfaceResumeBindingSnapshot? {
        guard let remoteWorkspaceID = inputs.remoteWorkspaceID else { return binding }
        guard let relayParameters = inputs.remoteRelayParameters else { return nil }

        switch self {
        case .workspace(_, let workspace, let surfaceID):
            guard remoteWorkspaceID == workspace.id,
                  WorkspaceRemoteRelayCommandRewriter.authenticatesRemoteResumeParameters(
                      relayParameters.mapValues(\.foundationObject),
                      remoteRelayTokenHex: workspace.remoteConfiguration?.relayToken
                  ),
                  let context = workspace.persistentSSHResumeContext(panelID: surfaceID) else {
                return nil
            }
            return binding.registeredForPersistentSSH(context)
        case .dock(_, let dock, let surfaceID):
            guard let registration = dock.persistentSSHResumeRegistration(panelId: surfaceID),
                  remoteWorkspaceID == registration.context.workspaceID,
                  WorkspaceRemoteRelayCommandRewriter.authenticatesRemoteResumeParameters(
                      relayParameters.mapValues(\.foundationObject),
                      remoteRelayTokenHex: registration.relayToken
                  ) else {
                return nil
            }
            return binding.registeredForPersistentSSH(registration.context)
        }
    }
}

extension SurfaceResumeBindingSnapshot {
    /// Applies the single app-owned Codex provenance invariant atomically with
    /// the surface binding mutation. Bindings created before provenance was
    /// persisted may establish or refresh another legacy binding, but cannot
    /// replace a binding that carries classified evidence.
    func allowsCodexAgentHookReplacement(of existing: SurfaceResumeBindingSnapshot?) -> Bool {
        guard isAgentHookBinding, kind?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "codex" else {
            return true
        }
        if resumeEvidenceProvenance == nil {
            guard let existing else { return true }
            let existingKind = existing.kind?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let existingIsLegacyCodex = existing.isAgentHookBinding && existingKind == nil
            guard existingKind == "codex" || existingIsLegacyCodex else {
                return true
            }
            return existing.isAgentHookBinding
                && existing.resumeEvidenceProvenance == nil
        }
        guard let incoming = codexResumeEvidenceProvenance,
              incoming.mayOwnBinding else { return false }
        guard let existing else {
            return true
        }
        let existingKind = existing.kind?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let existingIsLegacyCodex = existing.isAgentHookBinding && existingKind == nil
        guard existingKind == "codex" || existingIsLegacyCodex else {
            return true
        }
        guard let previous = existing.codexResumeEvidenceProvenance else {
            return incoming == .tui
        }
        return incoming.canReplace(previous)
    }

    private var codexResumeEvidenceProvenance: AgentResumeEvidenceProvenance? {
        switch resumeEvidenceProvenance?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "exec": .exec
        case "subagent": .subagent
        case "unknown": .unknown
        case "tui": .tui
        default: nil
        }
    }
}
