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
            // Assigning directly inside this observer avoids recursively re-entering it.
            for (panelId, state) in resumeStatesByPanelId where state == .awaitingAutoResumeCommand {
                if queuedRestoreSnapshotsByPanelId[panelId] == nil {
                    queuedRestoreSnapshotsByPanelId[panelId] = snapshotsByPanelId[panelId]
                }
                guard let queuedSnapshot = queuedRestoreSnapshotsByPanelId[panelId] else {
                    continue
                }
                guard let proposedSnapshot = snapshotsByPanelId[panelId],
                      Self.hasSameSessionIdentity(proposedSnapshot, queuedSnapshot) else {
                    snapshotsByPanelId[panelId] = queuedSnapshot
                    continue
                }
            }
            completedGenerationsByPanelId = completedGenerationsByPanelId.filter { panelId, _ in
                snapshotsByPanelId[panelId] != nil
            }
        }
    }
    private var queuedRestoreSnapshotsByPanelId: [UUID: SessionRestorableAgentSnapshot] = [:]
    var resumeStatesByPanelId: [UUID: Workspace.RestoredAgentResumeState] = [:] {
        didSet {
            completedGenerationsByPanelId = completedGenerationsByPanelId.filter { panelId, _ in
                resumeStatesByPanelId[panelId] == .completedAgentExit
            }
            for (panelId, state) in resumeStatesByPanelId where state == .completedAgentExit {
                guard completedGenerationsByPanelId[panelId] == nil,
                      snapshotsByPanelId[panelId] != nil else {
                    continue
                }
                completedGenerationsByPanelId[panelId] = RestoredAgentCompletedGeneration(
                    completedAt: dateProvider(),
                    processIdentities: []
                )
            }
            queuedRestoreSnapshotsByPanelId = queuedRestoreSnapshotsByPanelId.filter { panelId, _ in
                resumeStatesByPanelId[panelId] == .awaitingAutoResumeCommand
            }
            for (panelId, state) in resumeStatesByPanelId
                where state == .awaitingAutoResumeCommand && queuedRestoreSnapshotsByPanelId[panelId] == nil {
                queuedRestoreSnapshotsByPanelId[panelId] = snapshotsByPanelId[panelId]
            }
        }
    }
    var invalidatedFingerprintsByPanelId: [UUID: Int] = [:]
    /// Local resume targets retained while a restored launch owns the terminal.
    /// Split and tab creation use these to recover from transient shell cwd reports.
    var resumeWorkingDirectoriesByPanelId: [UUID: String] = [:]

    private var completedGenerationsByPanelId: [UUID: RestoredAgentCompletedGeneration] = [:]

    func markCompleted(
        panelId: UUID,
        observation: RestorableAgentSessionIndex.Entry?,
        runtimeProcessIdentities: Set<AgentPIDProcessIdentity>
    ) {
        let observedProcessIdentities = Set(
            observation.map { Array($0.agentProcessIdentities.values) } ?? []
        )
        completedGenerationsByPanelId[panelId] = RestoredAgentCompletedGeneration(
            completedAt: dateProvider(),
            processIdentities: runtimeProcessIdentities.union(observedProcessIdentities)
        )
        resumeStatesByPanelId[panelId] = .completedAgentExit
    }

    func continuationSnapshot(
        panelId: UUID,
        observation: RestorableAgentSessionIndex.Entry?,
        currentProcessIdentity: (pid_t) -> AgentPIDProcessIdentity?
    ) -> SessionRestorableAgentSnapshot? {
        guard resumeStatesByPanelId[panelId] == .completedAgentExit else {
            return snapshotsByPanelId[panelId]
        }
        guard let observation,
              observationSupersedesCompletion(
                  panelId: panelId,
                  observation: observation,
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
        currentProcessIdentity: (pid_t) -> AgentPIDProcessIdentity?
    ) -> Bool {
        guard resumeStatesByPanelId[panelId] == .completedAgentExit,
              observationSupersedesCompletion(
                  panelId: panelId,
                  observation: observation,
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

    func completedGeneration(panelId: UUID) -> RestoredAgentCompletedGeneration? {
        completedGenerationsByPanelId[panelId]
    }

    /// Installs all lifecycle metadata for one newly restored terminal.
    func seedSessionRestore(
        panelId: UUID,
        snapshot: SessionRestorableAgentSnapshot?,
        manualResumeAvailable: Bool,
        willRunStartupCommand: Bool,
        willRunStartupInput: Bool,
        resumeWorkingDirectory: String?
    ) {
        let resumeState: Workspace.RestoredAgentResumeState?
        if willRunStartupCommand {
            resumeState = .autoResumeCommandRunning
        } else if willRunStartupInput {
            resumeState = .awaitingAutoResumeCommand
        } else if manualResumeAvailable {
            resumeState = .manualResumeAvailable
        } else {
            resumeState = nil
        }
        replaceQueuedRestoreSnapshot(
            resumeState == .awaitingAutoResumeCommand ? snapshot : nil,
            panelId: panelId
        )
        snapshotsByPanelId[panelId] = snapshot
        resumeStatesByPanelId[panelId] = resumeState

        let ownsStartupResume = resumeState == .awaitingAutoResumeCommand ||
            resumeState == .autoResumeCommandRunning
        replaceResumeWorkingDirectory(
            ownsStartupResume ? resumeWorkingDirectory : nil,
            panelId: panelId
        )
        invalidatedFingerprintsByPanelId.removeValue(forKey: panelId)
    }

    /// Removes continuation metadata without discarding an invalidation fingerprint.
    func clearSessionRestore(panelId: UUID) {
        queuedRestoreSnapshotsByPanelId.removeValue(forKey: panelId)
        resumeStatesByPanelId.removeValue(forKey: panelId)
        snapshotsByPanelId.removeValue(forKey: panelId)
        resumeWorkingDirectoriesByPanelId.removeValue(forKey: panelId)
    }

    /// Resets every restored-session lifecycle collection.
    func removeAllSessionRestores() {
        queuedRestoreSnapshotsByPanelId.removeAll(keepingCapacity: false)
        resumeStatesByPanelId.removeAll(keepingCapacity: false)
        snapshotsByPanelId.removeAll(keepingCapacity: false)
        invalidatedFingerprintsByPanelId.removeAll(keepingCapacity: false)
        resumeWorkingDirectoriesByPanelId.removeAll(keepingCapacity: false)
        completedGenerationsByPanelId.removeAll(keepingCapacity: false)
    }

    /// Shell integration has observed the restored launch enter its command
    /// phase and has not subsequently reported the prompt returning.
    func confirmsRunningRestoredCommand(panelId: UUID) -> Bool {
        switch resumeStatesByPanelId[panelId] {
        case .autoResumeCommandRunning, .observedAgentCommandRunning:
            true
        case .manualResumeAvailable, .awaitingAutoResumeCommand, .completedAgentExit, nil:
            false
        }
    }

    /// Keeps mutable observations from replacing the session targeted by queued startup input.
    @discardableResult
    func reconcileSnapshotWithQueuedRestoreIntent(
        panelId: UUID,
        proposedSnapshot: SessionRestorableAgentSnapshot?
    ) -> SessionRestorableAgentSnapshot? {
        guard resumeStatesByPanelId[panelId] == .awaitingAutoResumeCommand,
              let queuedSnapshot = queuedRestoreSnapshotsByPanelId[panelId] else {
            return proposedSnapshot
        }
        let resolvedSnapshot: SessionRestorableAgentSnapshot
        if let proposedSnapshot,
           Self.hasSameSessionIdentity(proposedSnapshot, queuedSnapshot) {
            resolvedSnapshot = proposedSnapshot
        } else {
            resolvedSnapshot = queuedSnapshot
        }
        snapshotsByPanelId[panelId] = resolvedSnapshot
        return resolvedSnapshot
    }

    /// The restore selector for the matching structured session is queued but
    /// no shell callback has started it yet.
    func hasQueuedRestoreIntent(
        panelId: UUID,
        matching snapshot: SessionRestorableAgentSnapshot?
    ) -> Bool {
        guard resumeStatesByPanelId[panelId] == .awaitingAutoResumeCommand,
              let queuedSnapshot = queuedRestoreSnapshotsByPanelId[panelId],
              let snapshot else {
            return false
        }
        return Self.hasSameSessionIdentity(queuedSnapshot, snapshot)
    }

    /// The restored launch still owns its binding while startup input is
    /// queued, even though only a later shell callback can prove it is running.
    func ownsInFlightRestoredCommand(panelId: UUID) -> Bool {
        switch resumeStatesByPanelId[panelId] {
        case .awaitingAutoResumeCommand, .autoResumeCommandRunning, .observedAgentCommandRunning:
            true
        case .manualResumeAvailable, .completedAgentExit, nil:
            false
        }
    }

    func seedTransferredState(
        panelId: UUID,
        snapshot: SessionRestorableAgentSnapshot?,
        resumeState: Workspace.RestoredAgentResumeState?,
        completedGeneration: RestoredAgentCompletedGeneration?,
        resumeWorkingDirectory: String?
    ) {
        replaceQueuedRestoreSnapshot(
            resumeState == .awaitingAutoResumeCommand ? snapshot : nil,
            panelId: panelId
        )
        if let snapshot {
            snapshotsByPanelId[panelId] = snapshot
        } else {
            snapshotsByPanelId.removeValue(forKey: panelId)
        }

        if resumeState == .completedAgentExit, let completedGeneration {
            completedGenerationsByPanelId[panelId] = completedGeneration
        } else {
            completedGenerationsByPanelId.removeValue(forKey: panelId)
        }

        if let resumeState {
            resumeStatesByPanelId[panelId] = resumeState
        } else {
            resumeStatesByPanelId.removeValue(forKey: panelId)
        }
        replaceResumeWorkingDirectory(resumeWorkingDirectory, panelId: panelId)
    }

    private func replaceQueuedRestoreSnapshot(
        _ snapshot: SessionRestorableAgentSnapshot?,
        panelId: UUID
    ) {
        if let snapshot {
            queuedRestoreSnapshotsByPanelId[panelId] = snapshot
        } else {
            queuedRestoreSnapshotsByPanelId.removeValue(forKey: panelId)
        }
    }

    private static func hasSameSessionIdentity(
        _ lhs: SessionRestorableAgentSnapshot,
        _ rhs: SessionRestorableAgentSnapshot
    ) -> Bool {
        lhs.kind.rawValue == rhs.kind.rawValue &&
            ManagedAgentSessionIdentity.sessionIDsMatch(
                kind: lhs.kind.rawValue,
                lhs: lhs.sessionId,
                rhs: rhs.sessionId
            )
    }

    private func replaceResumeWorkingDirectory(_ directory: String?, panelId: UUID) {
        guard let directory = directory?.trimmingCharacters(in: .whitespacesAndNewlines),
              !directory.isEmpty else {
            resumeWorkingDirectoriesByPanelId.removeValue(forKey: panelId)
            return
        }
        resumeWorkingDirectoriesByPanelId[panelId] = directory
    }

    private func observationSupersedesCompletion(
        panelId: UUID,
        observation: RestorableAgentSessionIndex.Entry,
        currentProcessIdentity: (pid_t) -> AgentPIDProcessIdentity?
    ) -> Bool {
        guard let completed = completedGenerationsByPanelId[panelId] else {
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
        return false
    }
}
