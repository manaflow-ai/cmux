@_spi(CmuxHostTransport) import CmuxExtensionKit
import Darwin
import Foundation

/// Exports native agent evidence only when it belongs to this panel and this
/// live process generation. A live PID alone never means the agent is working.
@MainActor
struct SidebarExtensionRuntimeProjector {
    var processIdentity: (pid_t) -> AgentPIDProcessIdentity? = { AgentPIDProcessIdentity(pid: $0) }

    func observation(workspace: Workspace, panelID: UUID) -> CmuxSidebarRuntimeObservation? {
        let model = workspace.sidebarAgentRuntimeObservation
        let keys = model.agentPIDKeysByPanelId[panelID] ?? []
        let candidates = model.agentPIDs.keys.sorted().compactMap { key -> CmuxSidebarRuntimeObservation? in
            let mappedPanel = model.agentPIDPanelIdsByKey[key]
            guard mappedPanel == panelID || (mappedPanel == nil && keys.contains(key)),
                  let pid = model.agentPIDs[key],
                  let recorded = model.agentPIDProcessIdentitiesByKey[key],
                  recorded.pid == pid, processIdentity(pid) == recorded else { return nil }
            let statusKey = workspace.agentStatusKey(forAgentPIDKey: key)
            guard !AgentHibernationLifecycleStatusKeys.isManualKey(statusKey) else { return nil }
            guard let generation = birthGeneration(recorded) else { return nil }
            let bornAt = Date(timeIntervalSince1970: Double(recorded.startSeconds) + Double(recorded.startMicroseconds) / 1_000_000)
            let sessionID = key.hasPrefix(statusKey + ".") ? String(key.dropFirst(statusKey.count + 1)) : nil
            guard let evidence = model.lifecycleEvidenceByPanelID[panelID]?[statusKey],
                  evidence.agentPIDKey == key, evidence.processIdentity == recorded,
                  evidence.observedAt >= bornAt,
                  model.agentLifecycleStatesByPanelId[panelID]?[statusKey] == evidence.lifecycle else {
                return CmuxSidebarRuntimeObservation(
                    lifecycle: .unknown,
                    provenance: .nativeProcess,
                    sessionID: sessionID,
                    toolID: statusKey,
                    processGeneration: generation
                )
            }
            let lifecycle: CmuxSidebarAgentLifecycle
            switch evidence.lifecycle {
            case .unknown: lifecycle = .unknown
            case .running: lifecycle = .running
            case .idle: lifecycle = .idle
            case .needsInput:
                lifecycle = evidence.isError ? .error : .needsInput
            }
            return CmuxSidebarRuntimeObservation(
                lifecycle: lifecycle,
                observedAt: evidence.observedAt,
                provenance: .nativeLifecycle,
                sessionID: sessionID,
                toolID: statusKey,
                processGeneration: generation
            )
        }
        // Several agents may share one pane. Preserve native aggregate
        // precedence; ties are stable by the sorted native key above.
        return candidates.max { rank($0.lifecycle) < rank($1.lifecycle) }
    }

    private func birthGeneration(_ identity: AgentPIDProcessIdentity) -> UInt64? {
        guard identity.startSeconds > 0, identity.startMicroseconds >= 0,
              identity.startMicroseconds < 1_000_000 else { return nil }
        let (seconds, overflow) = UInt64(identity.startSeconds).multipliedReportingOverflow(by: 1_000_000)
        guard !overflow else { return nil }
        return seconds + UInt64(identity.startMicroseconds)
    }

    private func rank(_ state: CmuxSidebarAgentLifecycle) -> Int {
        switch state {
        case .running: return 4
        case .error: return 3
        case .needsInput: return 2
        case .unknown: return 1
        case .idle: return 0
        }
    }
}
