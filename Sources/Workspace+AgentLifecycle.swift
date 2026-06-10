import Foundation
import SwiftUI
import AppKit
import Bonsplit
import CMUXAgentLaunch
import CmuxSocketControl
import Combine
import CryptoKit
import Darwin
import Network
import CoreText


// MARK: - Agent lifecycle, hibernation, and resume bindings
extension Workspace {
    func setAgentLifecycle(
        key: String,
        panelId: UUID?,
        lifecycle: AgentHibernationLifecycleState
    ) {
        let targetPanelId = panelId ?? focusedPanelId
        guard let targetPanelId, panels[targetPanelId] != nil else { return }
        agentLifecycleStatesByPanelId[targetPanelId, default: [:]][key] = lifecycle
        recordAgentLifecycleChange(panelId: targetPanelId)
    }

    @discardableResult
    func clearAgentLifecycle(key: String, panelId: UUID? = nil) -> Bool {
        var didClear = false
        let panelIds = panelId.map { [$0] } ?? Array(agentLifecycleStatesByPanelId.keys)
        for panelId in panelIds {
            guard agentLifecycleStatesByPanelId[panelId]?[key] != nil else { continue }
            agentLifecycleStatesByPanelId[panelId]?.removeValue(forKey: key)
            if agentLifecycleStatesByPanelId[panelId]?.isEmpty == true {
                agentLifecycleStatesByPanelId.removeValue(forKey: panelId)
            }
            didClear = true
            recordAgentLifecycleChange(panelId: panelId)
        }
        return didClear
    }

    func clearAgentLifecycleStates(panelId: UUID) {
        guard agentLifecycleStatesByPanelId.removeValue(forKey: panelId) != nil else { return }
        recordAgentLifecycleChange(panelId: panelId)
    }

    func clearAllAgentLifecycleStates() {
        let panelIds = Array(agentLifecycleStatesByPanelId.keys)
        guard !panelIds.isEmpty else { return }
        agentLifecycleStatesByPanelId.removeAll()
        for panelId in panelIds {
            recordAgentLifecycleChange(panelId: panelId)
        }
    }

    private func recordAgentLifecycleChange(panelId: UUID) {
        AgentHibernationController.shared.recordAgentLifecycleChange(
            workspaceId: id,
            panelId: panelId
        )
    }

    func agentHibernationLifecycleState(
        panelId: UUID,
        fallback: AgentHibernationLifecycleState?
    ) -> AgentHibernationLifecycleState {
        guard let panelStates = agentLifecycleStatesByPanelId[panelId],
              !panelStates.isEmpty else {
            return fallback ?? .unknown
        }
        let states = Array(panelStates.values)
        if states.contains(.running) { return .running }
        if states.contains(.needsInput) { return .needsInput }
        if states.contains(.unknown) { return .unknown }
        if states.contains(.idle) { return .idle }
        return fallback ?? .unknown
    }

    func restorableAgentForHibernation(
        panelId: UUID,
        index: RestorableAgentSessionIndex
    ) -> SessionRestorableAgentSnapshot? {
        guard let snapshot = restoredAgentSnapshotsByPanelId[panelId] ?? index.snapshot(workspaceId: id, panelId: panelId),
              snapshot.resumeCommand != nil else {
            return nil
        }
        let fingerprint = TabManager.restorableAgentSnapshotFingerprint(snapshot)
        guard invalidatedRestoredAgentFingerprintsByPanelId[panelId] != fingerprint else {
            return nil
        }
        return snapshot
    }

    func enterAgentHibernation(
        panelId: UUID,
        agent: SessionRestorableAgentSnapshot,
        lastActivityAt: Date
    ) {
        guard let terminalPanel = panels[panelId] as? TerminalPanel,
              !terminalPanel.isAgentHibernated else {
            return
        }
        guard agent.resumeCommand != nil else { return }
        restoredAgentSnapshotsByPanelId[panelId] = agent
        restoredAgentResumeStatesByPanelId[panelId] = .manualResumeAvailable
        invalidatedRestoredAgentFingerprintsByPanelId.removeValue(forKey: panelId)
        let keys = agentPIDKeysByPanelId[panelId] ?? []
        for key in keys {
            _ = clearAgentPID(key: key, panelId: panelId, clearStatus: false, refreshPorts: false)
        }
        if !keys.isEmpty {
            refreshTrackedAgentPorts()
        }
        terminalPanel.enterAgentHibernation(agent: agent, lastActivityAt: lastActivityAt)
    }

    @discardableResult
    func resumeAgentHibernation(panelId: UUID, focus: Bool) -> Bool {
        guard let terminalPanel = panels[panelId] as? TerminalPanel,
              terminalPanel.isAgentHibernated else {
            return false
        }
        let preparation = terminalPanel.prepareAgentHibernationResume()
        guard preparation.didResume else {
            return false
        }
        if restoredAgentSnapshotsByPanelId[panelId] != nil {
            restoredAgentResumeStatesByPanelId[panelId] = preparation.queuedStartupInput
                ? .awaitingAutoResumeCommand
                : .manualResumeAvailable
            invalidatedRestoredAgentFingerprintsByPanelId.removeValue(forKey: panelId)
        }
        clearAgentLifecycleStates(panelId: panelId)
        AgentHibernationController.shared.recordTerminalFocus(workspaceId: id, panelId: panelId)
        if focus {
            focusPanel(panelId)
        }
        return true
    }

    @discardableResult
    func resumeVisibleAgentHibernationPanels(panelIds: Set<UUID>) -> Bool {
        var didResume = false
        for panelId in panelIds {
            guard let terminalPanel = panels[panelId] as? TerminalPanel,
                  terminalPanel.isAgentHibernated else {
                continue
            }
            didResume = resumeAgentHibernation(panelId: panelId, focus: false) || didResume
        }
        return didResume
    }

    func restoredAgentResumeStateForAcceptedSnapshot(panelId: UUID) -> RestoredAgentResumeState {
        panelShellActivityStates[panelId] == .commandRunning
            ? .observedAgentCommandRunning
            : .manualResumeAvailable
    }

    func updateRestoredAgentResumeState(
        panelId: UUID,
        restoredAgent: SessionRestorableAgentSnapshot,
        shellState: PanelShellActivityState
    ) {
        switch shellState {
        case .commandRunning:
            switch restoredAgentResumeStatesByPanelId[panelId] {
            case .some(.awaitingAutoResumeCommand):
                restoredAgentResumeStatesByPanelId[panelId] = .autoResumeCommandRunning
            case .some(.autoResumeCommandRunning), .some(.observedAgentCommandRunning):
                break
            case .some(.manualResumeAvailable), nil:
                invalidateRestoredAgentSnapshot(panelId: panelId, restoredAgent: restoredAgent)
            }
        case .promptIdle:
            switch restoredAgentResumeStatesByPanelId[panelId] {
            case .some(.autoResumeCommandRunning), .some(.observedAgentCommandRunning):
                invalidateRestoredAgentSnapshot(panelId: panelId, restoredAgent: restoredAgent)
            case .some(.awaitingAutoResumeCommand), .some(.manualResumeAvailable), nil:
                break
            }
        case .unknown:
            break
        }
    }

    private func invalidateRestoredAgentSnapshot(
        panelId: UUID,
        restoredAgent: SessionRestorableAgentSnapshot
    ) {
        let fingerprint = TabManager.restorableAgentSnapshotFingerprint(restoredAgent)
        invalidatedRestoredAgentFingerprintsByPanelId[panelId] = fingerprint
        clearRestoredAgentResumeBinding(panelId: panelId, restoredAgent: restoredAgent)
        clearRestoredAgentSnapshot(panelId: panelId)
#if DEBUG
        cmuxDebugLog(
            "session.restore.agent.invalidate panel=\(panelId.uuidString.prefix(5)) " +
            "kind=\(restoredAgent.kind.rawValue) session=\(restoredAgent.sessionId.prefix(8))"
        )
#endif
    }

    func clearRestoredAgentSnapshot(panelId: UUID) {
        restoredAgentSnapshotsByPanelId.removeValue(forKey: panelId)
        restoredAgentResumeStatesByPanelId.removeValue(forKey: panelId)
    }

    private func clearRestoredAgentResumeBinding(
        panelId: UUID,
        restoredAgent: SessionRestorableAgentSnapshot
    ) {
        guard let binding = surfaceResumeBindingsByPanelId[panelId],
              binding.source == "agent-hook" else {
            return
        }
        let checkpointId = binding.checkpointId?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard checkpointId == nil || checkpointId == restoredAgent.sessionId else {
            return
        }
        surfaceResumeBindingsByPanelId.removeValue(forKey: panelId)
    }

    @discardableResult
    func setSurfaceResumeBinding(_ binding: SurfaceResumeBindingSnapshot, panelId: UUID) -> Bool {
        guard terminalPanel(for: panelId) != nil,
              let startupInput = binding.startupInput,
              !startupInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        surfaceResumeBindingsByPanelId[panelId] = binding
        return true
    }

    @discardableResult
    func clearSurfaceResumeBinding(panelId: UUID) -> Bool {
        surfaceResumeBindingsByPanelId.removeValue(forKey: panelId) != nil
    }

    func surfaceResumeBinding(panelId: UUID) -> SurfaceResumeBindingSnapshot? {
        surfaceResumeBindingsByPanelId[panelId]
    }

#if DEBUG
    func setRestoredAgentSnapshotForTesting(_ snapshot: SessionRestorableAgentSnapshot, panelId: UUID) {
        restoredAgentSnapshotsByPanelId[panelId] = snapshot
        invalidatedRestoredAgentFingerprintsByPanelId.removeValue(forKey: panelId)
    }

    func restoredAgentSnapshotForTesting(panelId: UUID) -> SessionRestorableAgentSnapshot? {
        restoredAgentSnapshotsByPanelId[panelId]
    }

    func setRestoredAgentAutoResumePendingForTesting(_ isPending: Bool, panelId: UUID) {
        if isPending {
            restoredAgentResumeStatesByPanelId[panelId] = .awaitingAutoResumeCommand
        } else {
            restoredAgentResumeStatesByPanelId.removeValue(forKey: panelId)
        }
    }

    func restoredAgentAutoResumePendingForTesting(panelId: UUID) -> Bool {
        restoredAgentResumeStatesByPanelId[panelId] == .awaitingAutoResumeCommand
    }
#endif

}
