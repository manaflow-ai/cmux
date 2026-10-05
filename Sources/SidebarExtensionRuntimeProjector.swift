import CmuxFoundation
@_spi(CmuxHostTransport) import CmuxExtensionKit
import CmuxAgentJournal
import Darwin
import Foundation

/// Exports exact registered sessions only while their native process birth is current.
@MainActor
struct SidebarExtensionRuntimeProjector {
    var processIdentity: (pid_t) -> AgentPIDProcessIdentity? = { AgentPIDProcessIdentity(pid: $0) }

    /// Legacy aggregate retained for API2.0/2.1 consumers.
    func observation(workspace: Workspace, panelID: UUID) -> CmuxSidebarRuntimeObservation? {
        candidates(workspace: workspace, panelID: panelID).max { rank($0.lifecycle) < rank($1.lifecycle) }
    }

    /// Keeps each verified process independent; unbound sessions retain a nil SID.
    func observations(workspace: Workspace, panelID: UUID) -> [CmuxSidebarRuntimeObservation]? {
        let exact = candidates(workspace: workspace, panelID: panelID)
        return exact.isEmpty ? nil : exact
    }

    private func candidates(workspace: Workspace, panelID: UUID) -> [CmuxSidebarRuntimeObservation] {
        let model = workspace.sidebarAgentRuntimeObservation
        let keys = model.agentPIDKeysByPanelId[panelID] ?? []
        return model.agentPIDs.keys.sorted().compactMap { key in
            let mappedPanel = model.agentPIDPanelIdsByKey[key]
            guard mappedPanel == panelID || (mappedPanel == nil && keys.contains(key)),
                  let pid = model.agentPIDs[key], let recorded = model.agentPIDProcessIdentitiesByKey[key],
                  recorded.pid == pid, processIdentity(pid) == recorded,
                  let generation = birthGeneration(recorded) else { return nil }
            let nativeStatusKey = workspace.agentStatusKey(forAgentPIDKey: key)
            let statusKey = AgentSemanticEventMapper().statusKey(nativeToolID: nativeStatusKey)
            guard !AgentHibernationLifecycleStatusKeys.isManualKey(statusKey) else { return nil }
            let bornAt = Date(timeIntervalSince1970: Double(generation) / 1_000_000)
            let sessionID = key.hasPrefix(nativeStatusKey + ".") ? String(key.dropFirst(nativeStatusKey.count + 1)) : nil
            var observation = CmuxSidebarRuntimeObservation(provenance: .nativeProcess, sessionID: sessionID, toolID: statusKey, processGeneration: generation, sampledAt: model.processSampledAtByKey[key])
            if let evidence = model.journalEvidenceByPanelID[panelID]?[key], evidence.processIdentity == recorded {
                let state = evidence.state
                if let timestamp = state.activityObservedAtMs, Date(timeIntervalSince1970: Double(timestamp) / 1_000) >= bornAt,
                   state.processGeneration == nil || state.processGeneration == generation {
                    observation.lifecycle = lifecycle(state.activity)
                    observation.activity = CmuxSidebarAgentActivity(rawValue: state.activity.rawValue) ?? .unknown
                    observation.reason = state.reason.flatMap { CmuxSidebarRuntimeReason(rawValue: $0.rawValue) }
                    observation.observedAt = Date(timeIntervalSince1970: Double(timestamp) / 1_000)
                    observation.transitionedAt = state.transitionedAtMs.map { Date(timeIntervalSince1970: Double($0) / 1_000) }
                    observation.provenance = .nativeLifecycle
                }
                if let timestamp = state.modeObservedAtMs, Date(timeIntervalSince1970: Double(timestamp) / 1_000) >= bornAt,
                   state.modeProcessGeneration == nil || state.modeProcessGeneration == generation {
                    observation.mode = CmuxSidebarAgentMode(rawValue: state.mode.rawValue) ?? .unknown
                    observation.modeObservedAt = Date(timeIntervalSince1970: Double(timestamp) / 1_000)
                    observation.provenance = .nativeLifecycle
                }
                if let timestamp = state.pendingUserActionsObservedAtMs, Date(timeIntervalSince1970: Double(timestamp) / 1_000) >= bornAt,
                   state.pendingUserActionsProcessGeneration == nil || state.pendingUserActionsProcessGeneration == generation {
                    observation.pendingUserActionCount = state.pendingUserActionCount
                    observation.provenance = .nativeLifecycle
                }
            }
            if let evidence = model.lifecycleEvidenceByPanelID[panelID]?[nativeStatusKey], evidence.agentPIDKey == key,
               evidence.processIdentity == recorded, evidence.observedAt >= bornAt,
               model.agentLifecycleStatesByPanelId[panelID]?[nativeStatusKey] == evidence.lifecycle,
               observation.observedAt == nil {
                switch evidence.lifecycle {
                case .unknown: observation.lifecycle = .unknown; observation.activity = .unknown
                case .running, .backgroundWorkPending: observation.lifecycle = .running; observation.activity = .working
                case .idle: observation.lifecycle = .idle; observation.activity = .idle
                case .needsInput: observation.lifecycle = evidence.isError ? .error : .needsInput; observation.activity = evidence.isError ? .failed : .needsInput
                }
                observation.reason = nil
                observation.observedAt = evidence.observedAt
                observation.transitionedAt = evidence.observedAt
                observation.provenance = .nativeLifecycle
            }
            return observation
        }
    }

    private func lifecycle(_ activity: AgentSessionActivity) -> CmuxSidebarAgentLifecycle {
        switch activity {
        case .working: return .running
        case .needsInput: return .needsInput
        case .failed, .quotaBlocked: return .error
        case .idle, .ready, .paused, .ended: return .idle
        case .unknown, .waiting: return .unknown
        }
    }

    private func birthGeneration(_ identity: AgentPIDProcessIdentity) -> UInt64? {
        guard identity.startSeconds > 0, identity.startMicroseconds >= 0, identity.startMicroseconds < 1_000_000 else { return nil }
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
