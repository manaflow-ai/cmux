import CmuxWorkspaces
import Foundation
import Observation

/// Owns restored-agent continuation state and the process generation completed by a terminal.
@MainActor
@Observable
final class RestoredAgentLifecycleCoordinator {
    @ObservationIgnored
    private let dateProvider: @MainActor () -> TimeInterval

    init(dateProvider: @escaping @MainActor () -> TimeInterval = { Date.now.timeIntervalSince1970 }) {
        self.dateProvider = dateProvider
    }

    var snapshotsByPanelId: [UUID: SessionRestorableAgentSnapshot] = [:] {
        didSet {
            completedGenerationsByPanelId = completedGenerationsByPanelId.filter { panelId, _ in
                snapshotsByPanelId[panelId] != nil
            }
        }
    }
    var resumeStatesByPanelId: [UUID: Workspace.RestoredAgentResumeState] = [:] {
        didSet {
            completedGenerationsByPanelId = completedGenerationsByPanelId.filter { panelId, _ in
                resumeStatesByPanelId[panelId] == .completedAgentExit
            }
            for (panelId, state) in resumeStatesByPanelId where state == .completedAgentExit {
                guard completedGenerationsByPanelId[panelId] == nil,
                      let snapshot = snapshotsByPanelId[panelId] else {
                    continue
                }
                completedGenerationsByPanelId[panelId] = RestoredAgentCompletedGeneration(
                    completedAt: dateProvider(),
                    updatedAt: snapshot.launchCommand?.capturedAt ?? 0,
                    processIdentities: []
                )
            }
        }
    }
    var invalidatedFingerprintsByPanelId: [UUID: Int] = [:]

    private var completedGenerationsByPanelId: [UUID: RestoredAgentCompletedGeneration] = [:]

    func markCompleted(
        panelId: UUID,
        snapshot: SessionRestorableAgentSnapshot,
        observation: RestorableAgentSessionIndex.Entry?,
        runtimeProcessIdentities: Set<AgentPIDProcessIdentity>
    ) {
        let observedProcessIdentities = Set(
            observation.map { Array($0.agentProcessIdentities.values) } ?? []
        )
        completedGenerationsByPanelId[panelId] = RestoredAgentCompletedGeneration(
            completedAt: dateProvider(),
            updatedAt: max(
                observation?.updatedAt ?? 0,
                snapshot.launchCommand?.capturedAt ?? 0
            ),
            processIdentities: runtimeProcessIdentities.union(observedProcessIdentities)
        )
        resumeStatesByPanelId[panelId] = .completedAgentExit
    }

    func continuationSnapshot(
        panelId: UUID,
        observation: RestorableAgentSessionIndex.Entry?,
        shellState: PanelShellActivityState?,
        currentProcessIdentity: (pid_t) -> AgentPIDProcessIdentity?
    ) -> SessionRestorableAgentSnapshot? {
        guard resumeStatesByPanelId[panelId] == .completedAgentExit else {
            return snapshotsByPanelId[panelId]
        }
        guard let observation,
              observationSupersedesCompletion(
                  panelId: panelId,
                  observation: observation,
                  shellState: shellState,
                  currentProcessIdentity: currentProcessIdentity
              ) else {
            return nil
        }
        return observation.snapshot
    }

    @discardableResult
    func reconcileCompletedAgent(
        panelId: UUID,
        observation: RestorableAgentSessionIndex.Entry,
        shellState: PanelShellActivityState?,
        currentProcessIdentity: (pid_t) -> AgentPIDProcessIdentity?
    ) -> Bool {
        guard resumeStatesByPanelId[panelId] == .completedAgentExit,
              observationSupersedesCompletion(
                  panelId: panelId,
                  observation: observation,
                  shellState: shellState,
                  currentProcessIdentity: currentProcessIdentity
              ) else {
            return false
        }
        snapshotsByPanelId[panelId] = observation.snapshot
        resumeStatesByPanelId[panelId] = .observedAgentCommandRunning
        invalidatedFingerprintsByPanelId.removeValue(forKey: panelId)
        completedGenerationsByPanelId.removeValue(forKey: panelId)
        return true
    }

    private func observationSupersedesCompletion(
        panelId: UUID,
        observation: RestorableAgentSessionIndex.Entry,
        shellState: PanelShellActivityState?,
        currentProcessIdentity: (pid_t) -> AgentPIDProcessIdentity?
    ) -> Bool {
        guard shellState == .commandRunning,
              let completed = completedGenerationsByPanelId[panelId] else {
            return false
        }

        let observedIdentities = Set(observation.agentProcessIdentities.values)
        let currentCandidateIdentities = Set(observedIdentities.filter { identity in
            currentProcessIdentity(identity.pid) == identity
        })
        if !observedIdentities.isEmpty {
            let newerIdentities = currentCandidateIdentities.subtracting(completed.processIdentities)
            return newerIdentities.contains { identity in
                let startedAt = TimeInterval(identity.startSeconds) +
                    TimeInterval(identity.startMicroseconds) / 1_000_000
                return startedAt > completed.completedAt
            }
        }

        guard observation.agentProcessIDs.isEmpty else { return false }
        return observation.updatedAt > max(completed.completedAt, completed.updatedAt)
    }
}
