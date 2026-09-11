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

    private(set) var snapshotsByPanelId: [UUID: SessionRestorableAgentSnapshot] = [:]
    /// Immutable session target retained until the staged startup command completes.
    private var queuedRestoreSnapshotsByPanelId: [UUID: SessionRestorableAgentSnapshot] = [:]
    private(set) var resumeStatesByPanelId: [UUID: Workspace.RestoredAgentResumeState] = [:]
    var invalidatedFingerprintsByPanelId: [UUID: Int] = [:]
    /// Local resume targets retained while a restored launch owns the terminal.
    /// Split and tab creation use these to recover from transient shell cwd reports.
    var resumeWorkingDirectoriesByPanelId: [UUID: String] = [:]

    private var completedGenerationsByPanelId: [UUID: RestoredAgentCompletedGeneration] = [:]

    /// Startup input a restored launch types into its shell, retained until shell
    /// integration reports the command running. Ghostty writes that input as soon
    /// as the PTY exists, and a slow login shell can discard the typeahead while it
    /// initializes, which leaves the pane at an idle prompt with nothing typed.
    /// The owner replays the retained input once when that happens (#5473).
    private var pendingStartupInputsByPanelId: [UUID: String] = [:]
    private var armedStartupInputResendPanelIds: Set<UUID> = []

    /// Replaces one panel's mutable snapshot while preserving an in-flight restore target.
    func setSnapshot(_ snapshot: SessionRestorableAgentSnapshot?, panelId: UUID) {
        let resolvedSnapshot: SessionRestorableAgentSnapshot?
        if Self.retainsStartupRestoreIdentity(resumeStatesByPanelId[panelId]) {
            if queuedRestoreSnapshotsByPanelId[panelId] == nil {
                replaceQueuedRestoreSnapshot(snapshot, panelId: panelId)
            }
            if let queuedSnapshot = queuedRestoreSnapshotsByPanelId[panelId] {
                if let snapshot, Self.hasSameSessionIdentity(snapshot, queuedSnapshot) {
                    resolvedSnapshot = snapshot
                } else {
                    resolvedSnapshot = queuedSnapshot
                }
            } else {
                resolvedSnapshot = snapshot
            }
        } else {
            resolvedSnapshot = snapshot
        }
        replaceSnapshot(resolvedSnapshot, panelId: panelId)
    }

    /// Replaces one panel's resume phase and updates only that panel's derived lifecycle state.
    func setResumeState(_ state: Workspace.RestoredAgentResumeState?, panelId: UUID) {
        replaceResumeState(state, panelId: panelId)
        if state == .completedAgentExit {
            if completedGenerationsByPanelId[panelId] == nil,
               snapshotsByPanelId[panelId] != nil {
                completedGenerationsByPanelId[panelId] = RestoredAgentCompletedGeneration(
                    completedAt: dateProvider(),
                    processIdentities: []
                )
            }
        } else {
            completedGenerationsByPanelId.removeValue(forKey: panelId)
        }

        if Self.retainsStartupRestoreIdentity(state) {
            if queuedRestoreSnapshotsByPanelId[panelId] == nil {
                replaceQueuedRestoreSnapshot(snapshotsByPanelId[panelId], panelId: panelId)
            }
        } else {
            queuedRestoreSnapshotsByPanelId.removeValue(forKey: panelId)
        }
    }

    /// Prunes lifecycle state in one bounded pass when the owning topology is bulk-replaced.
    func retainSessionRestores(for validPanelIds: Set<UUID>) {
        resumeStatesByPanelId = resumeStatesByPanelId.filter { validPanelIds.contains($0.key) }
        snapshotsByPanelId = snapshotsByPanelId.filter { validPanelIds.contains($0.key) }
        queuedRestoreSnapshotsByPanelId = queuedRestoreSnapshotsByPanelId.filter { panelId, _ in
            validPanelIds.contains(panelId) &&
                Self.retainsStartupRestoreIdentity(resumeStatesByPanelId[panelId])
        }
        for (panelId, state) in resumeStatesByPanelId
            where Self.retainsStartupRestoreIdentity(state) &&
                queuedRestoreSnapshotsByPanelId[panelId] == nil {
            replaceQueuedRestoreSnapshot(snapshotsByPanelId[panelId], panelId: panelId)
        }
        completedGenerationsByPanelId = completedGenerationsByPanelId.filter { panelId, _ in
            resumeStatesByPanelId[panelId] == .completedAgentExit
        }
    }

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
        setResumeState(.completedAgentExit, panelId: panelId)
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
        setSnapshot(observation.snapshot, panelId: panelId)
        setResumeState(.observedAgentCommandRunning, panelId: panelId)
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
            Self.retainsStartupRestoreIdentity(resumeState) ? snapshot : nil,
            panelId: panelId
        )
        replaceSnapshot(snapshot, panelId: panelId)
        setResumeState(resumeState, panelId: panelId)

        let ownsStartupResume = resumeState == .awaitingAutoResumeCommand ||
            resumeState == .autoResumeCommandRunning
        replaceResumeWorkingDirectory(
            ownsStartupResume ? resumeWorkingDirectory : nil,
            panelId: panelId
        )
        invalidatedFingerprintsByPanelId.removeValue(forKey: panelId)
    }

    /// Retains the startup input a restored launch will type into its shell.
    /// Passing `nil` or an empty string forgets any earlier registration.
    func registerStartupInput(_ input: String?, panelId: UUID) {
        armedStartupInputResendPanelIds.remove(panelId)
        guard let input, !input.isEmpty else {
            pendingStartupInputsByPanelId.removeValue(forKey: panelId)
            return
        }
        pendingStartupInputsByPanelId[panelId] = input
    }

    /// Forgets retained startup input once the shell ran it, the user took over
    /// the pane, or the launch was abandoned.
    func clearStartupInput(panelId: UUID) {
        pendingStartupInputsByPanelId.removeValue(forKey: panelId)
        armedStartupInputResendPanelIds.remove(panelId)
    }

    /// The retained startup input, so a pane transfer can carry it to the new owner.
    func startupInput(panelId: UUID) -> String? {
        pendingStartupInputsByPanelId[panelId]
    }

    /// Whether a restored launch is still waiting for its typed startup input to run.
    func awaitsStartupInput(panelId: UUID) -> Bool {
        resumeStatesByPanelId[panelId] == .awaitingAutoResumeCommand &&
            pendingStartupInputsByPanelId[panelId] != nil
    }

    /// Arms one grace-period replay for a launch whose shell reported an idle
    /// prompt while the launch still awaits its startup input. Returns `false`
    /// when nothing is pending or a replay is already armed.
    func armStartupInputResend(panelId: UUID) -> Bool {
        guard awaitsStartupInput(panelId: panelId),
              !armedStartupInputResendPanelIds.contains(panelId) else {
            return false
        }
        armedStartupInputResendPanelIds.insert(panelId)
        return true
    }

    /// Consumes the retained startup input when the shell is still idle after
    /// the grace period and the launch never entered its command phase. A
    /// prompt-then-command sequence that settled into `.autoResumeCommandRunning`
    /// yields `nil`, and only one replay is ever handed out per restored launch.
    func takeStartupInputForResend(
        panelId: UUID,
        shellState: PanelShellActivityState
    ) -> String? {
        armedStartupInputResendPanelIds.remove(panelId)
        guard shellState == .promptIdle, awaitsStartupInput(panelId: panelId) else {
            return nil
        }
        return pendingStartupInputsByPanelId.removeValue(forKey: panelId)
    }

    /// Removes continuation metadata without discarding an invalidation fingerprint.
    func clearSessionRestore(panelId: UUID) {
        queuedRestoreSnapshotsByPanelId.removeValue(forKey: panelId)
        resumeStatesByPanelId.removeValue(forKey: panelId)
        snapshotsByPanelId.removeValue(forKey: panelId)
        resumeWorkingDirectoriesByPanelId.removeValue(forKey: panelId)
        completedGenerationsByPanelId.removeValue(forKey: panelId)
        clearStartupInput(panelId: panelId)
    }

    /// Resets every restored-session lifecycle collection.
    func removeAllSessionRestores() {
        queuedRestoreSnapshotsByPanelId.removeAll(keepingCapacity: false)
        resumeStatesByPanelId.removeAll(keepingCapacity: false)
        snapshotsByPanelId.removeAll(keepingCapacity: false)
        invalidatedFingerprintsByPanelId.removeAll(keepingCapacity: false)
        resumeWorkingDirectoriesByPanelId.removeAll(keepingCapacity: false)
        completedGenerationsByPanelId.removeAll(keepingCapacity: false)
        pendingStartupInputsByPanelId.removeAll(keepingCapacity: false)
        armedStartupInputResendPanelIds.removeAll(keepingCapacity: false)
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
        guard Self.retainsStartupRestoreIdentity(resumeStatesByPanelId[panelId]),
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
        setSnapshot(resolvedSnapshot, panelId: panelId)
        return snapshotsByPanelId[panelId]
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
        resumeWorkingDirectory: String?,
        startupInput: String? = nil
    ) {
        // A launch still awaiting its typed selector keeps the replay safety
        // net across a Workspace/Dock move; any other phase has nothing to replay.
        registerStartupInput(
            resumeState == .awaitingAutoResumeCommand ? startupInput : nil,
            panelId: panelId
        )
        replaceQueuedRestoreSnapshot(
            Self.retainsStartupRestoreIdentity(resumeState) ? snapshot : nil,
            panelId: panelId
        )
        if let snapshot {
            replaceSnapshot(snapshot, panelId: panelId)
        } else {
            replaceSnapshot(nil, panelId: panelId)
        }

        if resumeState == .completedAgentExit, let completedGeneration {
            completedGenerationsByPanelId[panelId] = completedGeneration
        } else {
            completedGenerationsByPanelId.removeValue(forKey: panelId)
        }

        setResumeState(resumeState, panelId: panelId)
        replaceResumeWorkingDirectory(resumeWorkingDirectory, panelId: panelId)
    }

    private func replaceSnapshot(_ snapshot: SessionRestorableAgentSnapshot?, panelId: UUID) {
        if let snapshot {
            snapshotsByPanelId[panelId] = snapshot
        } else {
            snapshotsByPanelId.removeValue(forKey: panelId)
        }
    }

    private func replaceResumeState(_ state: Workspace.RestoredAgentResumeState?, panelId: UUID) {
        if let state {
            resumeStatesByPanelId[panelId] = state
        } else {
            resumeStatesByPanelId.removeValue(forKey: panelId)
        }
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

    /// Generic shell activity cannot replace the staged session before startup completes.
    private static func retainsStartupRestoreIdentity(
        _ state: Workspace.RestoredAgentResumeState?
    ) -> Bool {
        switch state {
        case .awaitingAutoResumeCommand, .autoResumeCommandRunning:
            true
        case .manualResumeAvailable, .observedAgentCommandRunning, .completedAgentExit, nil:
            false
        }
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
