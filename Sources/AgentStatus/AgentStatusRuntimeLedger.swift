import CmuxWorkspaces
import Foundation

/// Workspace-owned history of raw observations and their latest reconciled projections.
@MainActor
final class AgentStatusRuntimeLedger {
    private static let titleActivityMinimumInterval: TimeInterval = 5

    private(set) var evidenceByPanelId: [UUID: [String: AgentStatusEvidence]] = [:]
    private(set) var resolutionsByPanelId: [UUID: [String: AgentStatusResolution]] = [:]

    func evidence(
        panelId: UUID,
        statusKey: String,
        shellActivity: PanelShellActivityState
    ) -> AgentStatusEvidence {
        var evidence = evidenceByPanelId[panelId]?[statusKey] ?? AgentStatusEvidence()
        evidence.shellActivity = shellActivity
        return evidence
    }

    @discardableResult
    func recordLifecycle(
        _ lifecycle: AgentHibernationLifecycleState,
        panelId: UUID,
        statusKey: String,
        observedAt: Date
    ) -> Bool {
        var evidence = evidenceByPanelId[panelId]?[statusKey] ?? AgentStatusEvidence()
        if let current = evidence.lifecycleObservedAt, current > observedAt { return false }
        evidence.lifecycle = lifecycle
        evidence.lifecycleObservedAt = observedAt
        evidenceByPanelId[panelId, default: [:]][statusKey] = evidence
        return true
    }

    func recordOutput(panelId: UUID, statusKeys: Set<String>, observedAt: Date) {
        updateEvidence(panelId: panelId, statusKeys: statusKeys) { evidence in
            guard evidence.outputObservedAt.map({ $0 < observedAt }) ?? true else { return false }
            evidence.outputObservedAt = observedAt
            return true
        }
    }

    func recordTitle(panelId: UUID, statusKeys: Set<String>, observedAt: Date) {
        updateEvidence(panelId: panelId, statusKeys: statusKeys) { evidence in
            guard evidence.titleObservedAt.map({
                observedAt.timeIntervalSince($0) >= Self.titleActivityMinimumInterval
            }) ?? true else { return false }
            evidence.titleObservedAt = observedAt
            return true
        }
    }

    func recordForegroundAgent(
        statusKey: String?,
        panelId: UUID,
        trackedStatusKeys: Set<String>,
        observedAt: Date
    ) {
        updateEvidence(panelId: panelId, statusKeys: trackedStatusKeys) { evidence in
            guard evidence.foregroundObservedAt.map({ $0 <= observedAt }) ?? true else { return false }
            evidence.foregroundAgentStatusKey = statusKey
            evidence.foregroundObservedAt = observedAt
            return true
        }
    }

    func seedLifecycleIfMissing(
        _ lifecycle: AgentHibernationLifecycleState?,
        panelId: UUID,
        statusKey: String
    ) {
        guard let lifecycle,
              evidenceByPanelId[panelId]?[statusKey]?.lifecycle == nil else { return }
        var evidence = evidenceByPanelId[panelId]?[statusKey] ?? AgentStatusEvidence()
        evidence.lifecycle = lifecycle
        // Legacy/restored panel lifecycle has no panel-local observation time.
        // Never borrow the workspace-wide status timestamp: another panel can
        // refresh that aggregate and make this panel's stale evidence look new.
        evidence.lifecycleObservedAt = nil
        evidenceByPanelId[panelId, default: [:]][statusKey] = evidence
    }

    func setResolution(
        _ resolution: AgentStatusResolution?,
        panelId: UUID,
        statusKey: String
    ) {
        if let resolution {
            resolutionsByPanelId[panelId, default: [:]][statusKey] = resolution
        } else {
            resolutionsByPanelId[panelId]?.removeValue(forKey: statusKey)
            if resolutionsByPanelId[panelId]?.isEmpty == true {
                resolutionsByPanelId.removeValue(forKey: panelId)
            }
        }
    }

    func evidenceForPanel(_ panelId: UUID) -> [String: AgentStatusEvidence] {
        evidenceByPanelId[panelId] ?? [:]
    }

    func resolutionsForPanel(_ panelId: UUID) -> [String: AgentStatusResolution] {
        resolutionsByPanelId[panelId] ?? [:]
    }

    func adopt(
        evidence: [String: AgentStatusEvidence],
        resolutions: [String: AgentStatusResolution],
        panelId: UUID
    ) {
        if !evidence.isEmpty { evidenceByPanelId[panelId] = evidence }
        if !resolutions.isEmpty { resolutionsByPanelId[panelId] = resolutions }
    }

    func remove(statusKey: String, panelId: UUID) {
        evidenceByPanelId[panelId]?.removeValue(forKey: statusKey)
        resolutionsByPanelId[panelId]?.removeValue(forKey: statusKey)
        pruneEmptyPanel(panelId)
    }

    func removePanel(_ panelId: UUID) {
        evidenceByPanelId.removeValue(forKey: panelId)
        resolutionsByPanelId.removeValue(forKey: panelId)
    }

    func removeAll() {
        evidenceByPanelId.removeAll()
        resolutionsByPanelId.removeAll()
    }

    private func updateEvidence(
        panelId: UUID,
        statusKeys: Set<String>,
        update: (inout AgentStatusEvidence) -> Bool
    ) {
        for statusKey in statusKeys {
            var evidence = evidenceByPanelId[panelId]?[statusKey] ?? AgentStatusEvidence()
            guard update(&evidence) else { continue }
            evidenceByPanelId[panelId, default: [:]][statusKey] = evidence
        }
    }

    private func pruneEmptyPanel(_ panelId: UUID) {
        if evidenceByPanelId[panelId]?.isEmpty == true { evidenceByPanelId.removeValue(forKey: panelId) }
        if resolutionsByPanelId[panelId]?.isEmpty == true { resolutionsByPanelId.removeValue(forKey: panelId) }
    }
}
