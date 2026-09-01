import Foundation
import CmuxWorkspaces

struct AgentHibernationPanelKey: Hashable, Sendable {
    let workspaceId: UUID
    let panelId: UUID
}

@MainActor
struct AgentHibernationRecord {
    let key: AgentHibernationPanelKey
    let workspace: Workspace
    let terminalPanel: TerminalPanel
    let agent: SessionRestorableAgentSnapshot
    let lifecycle: AgentHibernationLifecycleState
    let hasUnconfirmedTerminalInput: Bool
    let lastActivityAt: TimeInterval
    let isProtected: Bool
    let hasLiveProcess: Bool
    let containsUnrelatedProcess: Bool
    let panelProcessIDs: Set<Int>
    let processIDs: Set<Int>
    let processIdentities: [Int: AgentPIDProcessIdentity]
    private(set) var processLiveness: RestorableAgentProcessLiveness = .unknown
}

@MainActor
final class AgentHibernationController {
    static let shared = AgentHibernationController()

    static let unableToProtectRetrySeconds: TimeInterval = 120

    private var timer: DispatchSourceTimer?
    private var settingsObserver: NSObjectProtocol?
    var evaluationPhase: EvaluationPhase = .idle
    var activityByPanel: [AgentHibernationPanelKey: TimeInterval] = [:]
    var terminalInputByPanel: [AgentHibernationPanelKey: TimeInterval] = [:]
    var lifecycleChangeByPanel: [AgentHibernationPanelKey: TimeInterval] = [:]
    var teardownValidationEpochByPanel: [AgentHibernationPanelKey: UInt64] = [:]
    var teardownValidationGeneration: UInt64 = 0
    var unableToProtectByPanel: [AgentHibernationPanelKey: UnableToProtectMarker] = [:]
    var postTeardownRestoreTasksByTranscriptPath: [String: PostTeardownRestoreTask] = [:]
    var postTeardownRestoreDrainTask: Task<Void, Never>?
    var postSnapshotValidationIndexSequence: UInt64 = 0
    var postSnapshotValidationIndexTask: PostSnapshotValidationIndexTask?
    var teardownInFlightByPanel: [AgentHibernationPanelKey: InFlightTeardown] = [:]
    var committedTerminationObservationsByPanelID: [UUID: CommittedTerminationObservation] = [:]
    var committedTerminationCleanupByPanelID: [UUID: CommittedTerminationCleanup] = [:]
    let processSnapshotCoordinator = AgentHibernationProcessSnapshotCoordinator()
    var confirmations: [AgentHibernationPanelKey: Confirmation] = [:]
    var tailFingerprintSamples: [AgentHibernationPanelKey: TailFingerprintSample] = [:]
    var memoryPressureEvaluation: (id: UUID, task: Task<Void, Never>)?

    private init() {}

    func start() {
        AgentHibernationTrackingGate.setEnabled(true)
        guard settingsObserver == nil else {
            updateTimerForCurrentSettings()
            return
        }
        settingsObserver = NotificationCenter.default.addObserver(
            forName: AgentHibernationSettings.didChangeNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                AgentHibernationController.shared.recordSettingsChange()
            }
        }
        updateTimerForCurrentSettings()
    }

    func stop() {
        timer?.cancel()
        timer = nil
        memoryPressureEvaluation?.task.cancel()
        memoryPressureEvaluation = nil
        AgentHibernationTrackingGate.setEnabled(false)
        clearTrackingState()
        if let settingsObserver {
            NotificationCenter.default.removeObserver(settingsObserver)
            self.settingsObserver = nil
        }
    }

    func recordTerminalInput(workspaceId: UUID, panelId: UUID, recordedAt: Date? = nil) {
        guard AgentHibernationTrackingGate.isEnabled() else { return }
        let key = AgentHibernationPanelKey(workspaceId: workspaceId, panelId: panelId)
        if let terminalInputAt = terminalInputByPanel[key],
           terminalInputAt > (lifecycleChangeByPanel[key] ?? 0) {
            return
        }
        let recordedAt = recordedAt ?? Date()
        recordActivity(workspaceId: workspaceId, panelId: panelId, recordedAt: recordedAt)
        terminalInputByPanel[key] = recordedAt.timeIntervalSince1970
    }

    func recordTerminalFocus(workspaceId: UUID, panelId: UUID, recordedAt: Date? = nil) {
        guard AgentHibernationTrackingGate.isEnabled() else { return }
        let recordedAt = recordedAt ?? Date()
        recordActivity(workspaceId: workspaceId, panelId: panelId, recordedAt: recordedAt)
    }

    func recordAgentLifecycleChange(workspaceId: UUID, panelId: UUID, recordedAt: Date? = nil) {
        guard AgentHibernationTrackingGate.isEnabled() else { return }
        let recordedAt = recordedAt ?? Date()
        let key = recordActivity(workspaceId: workspaceId, panelId: panelId, recordedAt: recordedAt)
        lifecycleChangeByPanel[key] = recordedAt.timeIntervalSince1970
    }

    func recordAgentProcessChange(workspaceId: UUID, panelId: UUID, recordedAt: Date? = nil) {
        guard AgentHibernationTrackingGate.isEnabled() else { return }
        let recordedAt = recordedAt ?? Date()
        recordActivity(workspaceId: workspaceId, panelId: panelId, recordedAt: recordedAt)
    }

    @discardableResult
    private func recordActivity(workspaceId: UUID, panelId: UUID, recordedAt: Date) -> AgentHibernationPanelKey {
        let key = AgentHibernationPanelKey(workspaceId: workspaceId, panelId: panelId)
        activityByPanel[key] = recordedAt.timeIntervalSince1970
        bumpTeardownValidationEpoch(key)
        confirmations.removeValue(forKey: key)
        unableToProtectByPanel.removeValue(forKey: key)
        return key
    }

    private func bumpTeardownValidationEpoch(_ key: AgentHibernationPanelKey) {
        teardownValidationEpochByPanel[key] = (teardownValidationEpochByPanel[key] ?? 0) &+ 1
    }

    private func recordSettingsChange() {
        teardownValidationGeneration = teardownValidationGeneration &+ 1
        confirmations = confirmations.filter { $0.value.trigger == .systemMemoryPressure }
        unableToProtectByPanel.removeAll(keepingCapacity: false)
        updateTimerForCurrentSettings()
    }

    private func updateTimerForCurrentSettings() {
        let enabled = AgentHibernationSettings.isEnabled()
        guard enabled else {
            timer?.cancel()
            timer = nil
            return
        }
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 5, repeating: 30)
        timer.setEventHandler {
            let now = Date()
            Task { @MainActor in
                AgentHibernationController.shared.scheduleEvaluation(now: now)
            }
        }
        timer.resume()
        self.timer = timer
    }

    @discardableResult
    func evaluate(
        index: RestorableAgentSessionIndex,
        settings: AgentHibernationSettings.Values,
        now: Date,
        trigger: AgentHibernationReclaimTrigger = .scheduled,
        teardownShouldProceed: (@MainActor () -> Bool)? = nil,
        onHibernationCompleted: (@MainActor (Int) -> Void)? = nil
    ) -> (hasCandidates: Bool, beganTeardowns: Bool) {
        guard trigger != .scheduled || settings.enabled else {
            return (false, false)
        }
        guard let appDelegate = AppDelegate.shared else {
            return (false, false)
        }

        let records = appDelegate.agentHibernationRecords(
            index: index,
            activityByPanel: activityByPanel,
            terminalInputByPanel: terminalInputByPanel,
            lifecycleChangeByPanel: lifecycleChangeByPanel
        )
        let nowTime = now.timeIntervalSince1970
        let isLiveByKey = Dictionary(uniqueKeysWithValues: records.map { record in
            (
                record.key,
                (record.terminalPanel.surface.hasLiveSurface || record.hasLiveProcess) &&
                    !record.terminalPanel.isAgentHibernated
            )
        })
        let liveRestorableCount = isLiveByKey.values.filter { $0 }.count
        let shouldMaintainTailSamples = liveRestorableCount >= settings.maxLiveTerminals
        var effectiveActivityByKey: [AgentHibernationPanelKey: TimeInterval] = [:]
        let plannerInputs = records.map { record in
            let isLive = isLiveByKey[record.key] ?? false
            var effectiveLastActivityAt = record.lastActivityAt
            let processSafetyAllowsHibernation = record.processSafetyAllowsHibernation
            if record.hasLiveProcess {
                let scheduledProcessIsUnsafe =
                    !record.processSafetyAllowsHibernation
                if trigger == .systemMemoryPressure || scheduledProcessIsUnsafe {
                    tailFingerprintSamples.removeValue(forKey: record.key)
                }
                if trigger == .scheduled && scheduledProcessIsUnsafe {
                    if confirmations[record.key]?.trigger == .scheduled {
                        confirmations.removeValue(forKey: record.key)
                    }
                    if teardownInFlightByPanel[record.key]?.trigger == .scheduled {
                        bumpTeardownValidationEpoch(record.key)
                    }
                    unableToProtectByPanel.removeValue(forKey: record.key)
                }
            }
            let canSampleTail = trigger == .scheduled
                ? processSafetyAllowsHibernation
                : !record.hasLiveProcess
            if shouldMaintainTailSamples,
               isLive,
               !record.isProtected,
               canSampleTail,
               record.lifecycle.allowsHibernation,
               !record.hasUnconfirmedTerminalInput,
               let tailActivityAt = updateTailFingerprintSample(record: record, now: nowTime) {
                effectiveLastActivityAt = max(record.lastActivityAt, tailActivityAt)
            }
            effectiveActivityByKey[record.key] = effectiveLastActivityAt
            let unableToProtectMarkerApplies = unableToProtectMarkerStillApplies(
                for: record,
                lastActivityAt: effectiveLastActivityAt,
                now: nowTime
            )
            return AgentHibernationPlannerInput(
                key: record.key,
                hasRestorableAgent: true,
                isLive: isLive,
                hasLiveProcess: record.hasLiveProcess,
                processSafetyAllowsHibernation: processSafetyAllowsHibernation,
                isProtected: record.isProtected,
                lifecycle: record.lifecycle,
                isTemporarilyUnableToProtect: unableToProtectMarkerApplies,
                hasUnconfirmedTerminalInput: record.hasUnconfirmedTerminalInput,
                lastActivityAt: effectiveLastActivityAt
            )
        }
        let selectedKeys = AgentHibernationPlanner.selectedPanelKeys(
            inputs: plannerInputs,
            settings: settings,
            now: nowTime,
            trigger: trigger
        )
        let currentKeys = Set(records.map(\.key))
        pruneTrackingState(
            currentKeys: currentKeys,
            selectedKeys: selectedKeys,
            trigger: trigger
        )

        let confirmedTeardowns = records.compactMap { record -> ConfirmedTeardownRequest? in
            guard selectedKeys.contains(record.key) else { return nil }
            return evaluateConfirmation(
                record: record,
                effectiveLastActivityAt: effectiveActivityByKey[record.key] ?? record.lastActivityAt,
                settings: settings,
                now: nowTime,
                trigger: trigger
            )
        }
        if !confirmedTeardowns.isEmpty {
            beginConfirmedTeardowns(
                confirmedTeardowns,
                shouldProceed: teardownShouldProceed,
                onCompletion: onHibernationCompleted
            )
        }
        return (!selectedKeys.isEmpty, !confirmedTeardowns.isEmpty)
    }

    private func evaluateConfirmation(
        record: AgentHibernationRecord,
        effectiveLastActivityAt: TimeInterval,
        settings: AgentHibernationSettings.Values,
        now: TimeInterval,
        trigger: AgentHibernationReclaimTrigger
    ) -> ConfirmedTeardownRequest? {
        guard record.lifecycle.allowsHibernation,
              !record.hasUnconfirmedTerminalInput,
              !record.isProtected,
              record.processSafetyAllowsHibernation,
              record.terminalPanel.surface.hasLiveSurface,
              !record.terminalPanel.isAgentHibernated else {
            confirmations.removeValue(forKey: record.key)
            unableToProtectByPanel.removeValue(forKey: record.key)
            return nil
        }
        if teardownInFlightByPanel[record.key] != nil { confirmations.removeValue(forKey: record.key); return nil }

        if let confirmation = confirmations[record.key],
           confirmation.trigger == trigger {
            guard now >= confirmation.dueAt else { return nil }
            guard effectiveLastActivityAt <= confirmation.sampledAt else {
                confirmations.removeValue(forKey: record.key)
                return nil
            }
            guard let fingerprint = hibernationFingerprint(for: record),
                  fingerprint == confirmation.fingerprint,
                  record.processIdentities == confirmation.processIdentities else {
                confirmations.removeValue(forKey: record.key)
                return nil
            }
            let requestID = UUID()
            teardownInFlightByPanel[record.key] = InFlightTeardown(
                requestID: requestID,
                trigger: trigger
            )
            confirmations.removeValue(forKey: record.key)
            return ConfirmedTeardownRequest(
                record: record,
                confirmationFingerprint: confirmation.fingerprint,
                effectiveLastActivityAt: effectiveLastActivityAt,
                requestID: requestID,
                epoch: teardownValidationEpochByPanel[record.key] ?? 0,
                generation: teardownValidationGeneration,
                trigger: trigger
            )
        }
        if confirmations[record.key]?.trigger == .systemMemoryPressure {
            return nil
        }

        guard let fingerprint = hibernationFingerprint(for: record) else { return nil }
        if let marker = unableToProtectByPanel[record.key],
           Self.unableToProtectMarkerStillApplies(
               marker,
               fingerprint: fingerprint,
               lastActivityAt: effectiveLastActivityAt,
               now: now
           ) {
            return nil
        }
        unableToProtectByPanel.removeValue(forKey: record.key)
        confirmations[record.key] = Confirmation(
            trigger: trigger,
            fingerprint: fingerprint,
            processIdentities: record.processIdentities,
            sampledAt: now,
            dueAt: now + settings.confirmationSeconds
        )
        return nil
    }

    private func unableToProtectMarkerStillApplies(
        for record: AgentHibernationRecord,
        lastActivityAt: TimeInterval,
        now: TimeInterval
    ) -> Bool {
        guard let marker = unableToProtectByPanel[record.key],
              let fingerprint = hibernationFingerprint(for: record),
              Self.unableToProtectMarkerStillApplies(
                  marker,
                  fingerprint: fingerprint,
                  lastActivityAt: lastActivityAt,
                  now: now
              ) else {
            unableToProtectByPanel.removeValue(forKey: record.key)
            return false
        }
        return true
    }

    private func updateTailFingerprintSample(
        record: AgentHibernationRecord,
        now: TimeInterval
    ) -> TimeInterval? {
        guard !record.terminalPanel.isAgentHibernated,
              record.terminalPanel.surface.hasLiveSurface,
              let fingerprint = hibernationFingerprint(for: record) else {
            tailFingerprintSamples.removeValue(forKey: record.key)
            confirmations.removeValue(forKey: record.key)
            return nil
        }

        let previousSample = tailFingerprintSamples[record.key]
        if let previousSample,
           previousSample.fingerprint == fingerprint {
            return previousSample.stableSince
        }

        let stableSince = Self.tailFingerprintStableSince(
            previousFingerprint: previousSample?.fingerprint,
            previousStableSince: previousSample?.stableSince,
            currentFingerprint: fingerprint,
            lastActivityAt: record.lastActivityAt,
            now: now
        )
        tailFingerprintSamples[record.key] = TailFingerprintSample(
            fingerprint: fingerprint,
            stableSince: stableSince
        )
        confirmations.removeValue(forKey: record.key)
        return stableSince
    }

    func hibernationFingerprint(for record: AgentHibernationRecord) -> String? {
        guard let tail = tailFingerprint(for: record.terminalPanel) else { return nil }
        return Self.scrollbackFingerprint(tail: tail, processIDs: record.processIDs)
    }

    static func unableToProtectMarkerStillApplies(
        _ marker: UnableToProtectMarker,
        fingerprint: String,
        lastActivityAt: TimeInterval,
        now: TimeInterval
    ) -> Bool {
        marker.fingerprint == fingerprint &&
            marker.lastActivityAt == lastActivityAt &&
            now < marker.retryAfter
    }

    nonisolated static func scrollbackFingerprint(tail: String, processIDs: Set<Int>) -> String {
        "scrollback:\(processIdentityFingerprint(processIDs)):\(tail)"
    }

    nonisolated static func tailFingerprintStableSince(
        previousFingerprint: String?,
        previousStableSince: TimeInterval?,
        currentFingerprint: String,
        lastActivityAt: TimeInterval,
        now: TimeInterval
    ) -> TimeInterval {
        if previousFingerprint == currentFingerprint {
            return previousStableSince ?? lastActivityAt
        }
        return now
    }

    private nonisolated static func processIdentityFingerprint(_ processIDs: Set<Int>) -> String {
        processIDs.sorted().map(String.init).joined(separator: ",")
    }

    private func tailFingerprint(for terminalPanel: TerminalPanel) -> String? {
        guard terminalPanel.surface.surface != nil else { return nil }
        return TerminalController.shared.readTerminalTextForHibernationFingerprint(
            terminalPanel: terminalPanel,
            lineLimit: 12
        )
    }

    private func clearTrackingState() {
        cancelEvaluation()
        cancelPostTeardownRestoreTasks()
        teardownValidationGeneration = teardownValidationGeneration &+ 1
        activityByPanel.removeAll(keepingCapacity: false)
        terminalInputByPanel.removeAll(keepingCapacity: false)
        lifecycleChangeByPanel.removeAll(keepingCapacity: false)
        teardownValidationEpochByPanel.removeAll(keepingCapacity: false)
        unableToProtectByPanel.removeAll(keepingCapacity: false)
        teardownInFlightByPanel.removeAll(keepingCapacity: false)
        confirmations.removeAll(keepingCapacity: false)
        tailFingerprintSamples.removeAll(keepingCapacity: false)
    }

    private func pruneTrackingState(
        currentKeys: Set<AgentHibernationPanelKey>,
        selectedKeys: Set<AgentHibernationPanelKey>,
        trigger: AgentHibernationReclaimTrigger
    ) {
        activityByPanel = activityByPanel.filter { currentKeys.contains($0.key) }
        terminalInputByPanel = terminalInputByPanel.filter { currentKeys.contains($0.key) }
        lifecycleChangeByPanel = lifecycleChangeByPanel.filter { currentKeys.contains($0.key) }
        teardownValidationEpochByPanel = teardownValidationEpochByPanel.filter { currentKeys.contains($0.key) }
        unableToProtectByPanel = unableToProtectByPanel.filter { currentKeys.contains($0.key) }
        teardownInFlightByPanel = teardownInFlightByPanel.filter { currentKeys.contains($0.key) }
        confirmations = confirmations.filter { key, confirmation in
            currentKeys.contains(key) &&
                (confirmation.trigger != trigger || selectedKeys.contains(key))
        }
        tailFingerprintSamples = tailFingerprintSamples.filter { currentKeys.contains($0.key) }
    }

    func clearMemoryPressureConfirmations() {
        confirmations = confirmations.filter { $0.value.trigger != .systemMemoryPressure }
    }

    func clearInFlightTeardown(_ key: AgentHibernationPanelKey, requestID: UUID) {
        guard teardownInFlightByPanel[key]?.requestID == requestID else { return }
        teardownInFlightByPanel.removeValue(forKey: key)
    }
}
