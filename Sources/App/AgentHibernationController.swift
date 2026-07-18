import AppKit
import CmuxWorkspaces
import Darwin
import Foundation

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
    let processEvidence: AgentHibernationProcessEvidence

    var processIDs: Set<Int> {
        processEvidence.processIDs.union(processEvidence.lease?.guardedProcessIDs ?? [])
    }

    var satisfiesPromptAndCloseGates: Bool {
        AgentHibernationController.passesPromptAndCloseGates(
            workspaceShellActivity: workspace.panelShellActivityStates[key.panelId],
            panelShellActivity: terminalPanel.shellActivity.state,
            rawNeedsConfirmClose: terminalPanel.needsConfirmClose(),
            workspaceNeedsConfirmClose: workspace.panelNeedsConfirmClose(panelId: key.panelId)
        )
    }

    init(
        key: AgentHibernationPanelKey,
        workspace: Workspace,
        terminalPanel: TerminalPanel,
        agent: SessionRestorableAgentSnapshot,
        lifecycle: AgentHibernationLifecycleState,
        hasUnconfirmedTerminalInput: Bool,
        lastActivityAt: TimeInterval,
        isProtected: Bool,
        processEvidence: AgentHibernationProcessEvidence
    ) {
        self.key = key
        self.workspace = workspace
        self.terminalPanel = terminalPanel
        self.agent = agent
        self.lifecycle = lifecycle
        self.hasUnconfirmedTerminalInput = hasUnconfirmedTerminalInput
        self.lastActivityAt = lastActivityAt
        self.isProtected = isProtected
        self.processEvidence = processEvidence
    }
}

@MainActor
final class AgentHibernationStartupRecoveryCoordinator {
    typealias RecoveryOperation = @Sendable (
        _ cancellationCheck: @escaping @Sendable () -> Bool
    ) async -> Int

    private let recoveryOperation: RecoveryOperation
    private var isStarted = false
    private var runGeneration: UInt64 = 0
    private var taskSequence: UInt64 = 0
    private var completedRunGeneration: UInt64?
    private var taskRunGeneration: UInt64?
    private var task: Task<Void, Never>?

    init(recoveryOperation: @escaping RecoveryOperation) {
        self.recoveryOperation = recoveryOperation
    }

    var hasDeferredRecoveryForCurrentStart: Bool {
        isStarted
            && task != nil
            && taskRunGeneration != runGeneration
    }

    func start() {
        if !isStarted {
            isStarted = true
            runGeneration &+= 1
        }
        scheduleIfNeeded()
    }

    func stop() {
        isStarted = false
        task?.cancel()
    }

    func requestRecovery() {
        guard isStarted else { return }
        // Coalesce any number of requests behind the current generation. Its
        // completion schedules exactly one successor for the newest request.
        runGeneration &+= 1
        scheduleIfNeeded()
    }

    private func scheduleIfNeeded() {
        guard isStarted,
              task == nil,
              completedRunGeneration != runGeneration else {
            return
        }
        taskSequence &+= 1
        let sequence = taskSequence
        let scheduledRunGeneration = runGeneration
        let recoveryOperation = recoveryOperation
        taskRunGeneration = scheduledRunGeneration
        task = Task.detached(priority: .utility) {
            _ = await recoveryOperation { Task.isCancelled }
            await MainActor.run { [weak self] in
                self?.taskDidFinish(
                    sequence: sequence,
                    runGeneration: scheduledRunGeneration
                )
            }
        }
    }

    private func taskDidFinish(sequence: UInt64, runGeneration: UInt64) {
        guard sequence == taskSequence,
              taskRunGeneration == runGeneration else {
            return
        }
        task = nil
        taskRunGeneration = nil
        completedRunGeneration = runGeneration
        scheduleIfNeeded()
    }
}

@MainActor
final class AgentHibernationController {
    static let shared = AgentHibernationController()

    static let unableToProtectRetrySeconds: TimeInterval = 120

    private let timerQueue = DispatchQueue(label: "com.cmux.agent-hibernation", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var hibernationIndexLoadInFlight = false
    private let transcriptRecoveryCoordinator = AgentHibernationStartupRecoveryCoordinator {
        cancellationCheck in
        let restored = await AgentHibernationTranscriptGuard.recoverPendingSnapshotsAwaitingLock(
            cancellationCheck: cancellationCheck
        )
        if restored > 0 {
            NSLog("[AgentHibernation] recovered %d protected transcript snapshot(s)", restored)
        }
        return restored
    }
    private var settingsObserver: NSObjectProtocol?
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
    private var teardownInFlightByPanel: [AgentHibernationPanelKey: InFlightTeardown] = [:]
    private var confirmations: [AgentHibernationPanelKey: Confirmation] = [:]
    private var tailFingerprintSamples: [AgentHibernationPanelKey: TailFingerprintSample] = [:]

    private init() {}

    nonisolated static func passesPromptAndCloseGates(
        workspaceShellActivity: PanelShellActivityState?,
        panelShellActivity: PanelShellActivityState,
        rawNeedsConfirmClose: Bool,
        workspaceNeedsConfirmClose: Bool
    ) -> Bool {
        workspaceShellActivity == .promptIdle &&
            panelShellActivity == .promptIdle &&
            !rawNeedsConfirmClose &&
            !workspaceNeedsConfirmClose
    }

    func start() {
        transcriptRecoveryCoordinator.start()
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
        transcriptRecoveryCoordinator.stop()
        timer?.cancel()
        timer = nil
        AgentHibernationTrackingGate.setEnabled(false)
        clearTrackingState(cancelRestoreMonitors: true)
        if let settingsObserver {
            NotificationCenter.default.removeObserver(settingsObserver)
            self.settingsObserver = nil
        }
    }

    func enqueueTranscriptRecovery() {
        transcriptRecoveryCoordinator.requestRecovery()
    }

    func recordTerminalInput(workspaceId: UUID, panelId: UUID, recordedAt: Date? = nil) {
        guard AgentHibernationTrackingGate.isEnabled() else { return }
        let recordedAt = recordedAt ?? Date()
        let key = recordActivity(workspaceId: workspaceId, panelId: panelId, recordedAt: recordedAt)
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
        teardownInFlightByPanel[key]?.invalidate()
        bumpTeardownValidationEpoch(key)
        confirmations.removeValue(forKey: key)
        unableToProtectByPanel.removeValue(forKey: key)
        return key
    }

    private func bumpTeardownValidationEpoch(_ key: AgentHibernationPanelKey) {
        teardownValidationEpochByPanel[key] = (teardownValidationEpochByPanel[key] ?? 0) &+ 1
    }

    private func recordSettingsChange() {
        teardownInFlightByPanel.values.forEach { $0.invalidate() }
        teardownValidationGeneration = teardownValidationGeneration &+ 1
        confirmations.removeAll(keepingCapacity: false)
        unableToProtectByPanel.removeAll(keepingCapacity: false)
        updateTimerForCurrentSettings()
    }

    private func updateTimerForCurrentSettings() {
        let enabled = AgentHibernationSettings.isEnabled()
        AgentHibernationTrackingGate.setEnabled(enabled)
        guard enabled else {
            timer?.cancel()
            timer = nil
            clearTrackingState()
            return
        }
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: timerQueue)
        timer.schedule(deadline: .now() + 5, repeating: 30)
        timer.setEventHandler {
            let now = Date()
            Task { @MainActor in
                guard !AgentHibernationController.shared.hibernationIndexLoadInFlight,
                      let appDelegate = AppDelegate.shared,
                      let panelKeys = appDelegate.agentHibernationOpenTerminalPanelKeys(
                          maximumCount: RestorableAgentSessionIndex.maximumHibernationPanelContexts
                      ) else { return }
                AgentHibernationController.shared.hibernationIndexLoadInFlight = true
                defer { AgentHibernationController.shared.hibernationIndexLoadInFlight = false }
                let index = await RestorableAgentSessionIndex.loadIncludingProcessDetectedSnapshots(
                    hibernationPanelKeys: panelKeys
                )
                let settings = AgentHibernationSettings.values()
                guard settings.enabled else { return }
                AgentHibernationController.shared.evaluate(index: index, settings: settings, now: now)
            }
        }
        timer.resume()
        self.timer = timer
    }

    private func evaluate(
        index: RestorableAgentSessionIndex,
        settings: AgentHibernationSettings.Values,
        now: Date
    ) {
        guard settings.enabled else {
            AgentHibernationTrackingGate.setEnabled(false)
            clearTrackingState()
            return
        }
        guard let appDelegate = AppDelegate.shared else { return }

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
                (record.terminalPanel.surface.hasLiveSurface || !record.processIDs.isEmpty) &&
                    !record.terminalPanel.isAgentHibernated
            )
        })
        let liveRestorableCount = isLiveByKey.values.filter { $0 }.count
        let shouldMaintainTailSamples = liveRestorableCount >= settings.maxLiveTerminals
        var effectiveActivityByKey: [AgentHibernationPanelKey: TimeInterval] = [:]
        let plannerInputs = records.map { record in
            let isLive = isLiveByKey[record.key] ?? false
            var effectiveLastActivityAt = record.lastActivityAt
            if !record.processEvidence.allowsHibernation || !record.satisfiesPromptAndCloseGates {
                bumpTeardownValidationEpoch(record.key)
                tailFingerprintSamples.removeValue(forKey: record.key)
                confirmations.removeValue(forKey: record.key)
                unableToProtectByPanel.removeValue(forKey: record.key)
            }
            if shouldMaintainTailSamples,
               isLive,
               !record.isProtected,
               record.processEvidence.allowsHibernation,
               record.satisfiesPromptAndCloseGates,
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
                processEvidence: record.processEvidence,
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
            now: nowTime
        )
        let currentKeys = Set(records.map(\.key))
        pruneTrackingState(currentKeys: currentKeys, selectedKeys: selectedKeys)

        let confirmedTeardowns = records.compactMap { record -> ConfirmedTeardownRequest? in
            guard selectedKeys.contains(record.key) else { return nil }
            return evaluateConfirmation(
                record: record,
                effectiveLastActivityAt: effectiveActivityByKey[record.key] ?? record.lastActivityAt,
                settings: settings,
                now: nowTime
            )
        }
        if !confirmedTeardowns.isEmpty { beginConfirmedTeardowns(confirmedTeardowns) }
    }

    private func evaluateConfirmation(
        record: AgentHibernationRecord,
        effectiveLastActivityAt: TimeInterval,
        settings: AgentHibernationSettings.Values,
        now: TimeInterval
    ) -> ConfirmedTeardownRequest? {
        guard record.lifecycle.allowsHibernation,
              !record.hasUnconfirmedTerminalInput,
              !record.isProtected,
              record.processEvidence.allowsHibernation,
              record.satisfiesPromptAndCloseGates,
              record.terminalPanel.surface.hasLiveSurface,
              !record.terminalPanel.isAgentHibernated else {
            confirmations.removeValue(forKey: record.key)
            unableToProtectByPanel.removeValue(forKey: record.key)
            return nil
        }
        if teardownInFlightByPanel[record.key] != nil { confirmations.removeValue(forKey: record.key); return nil }

        if let confirmation = confirmations[record.key] {
            guard now >= confirmation.dueAt else { return nil }
            guard effectiveLastActivityAt <= confirmation.sampledAt else {
                confirmations.removeValue(forKey: record.key)
                return nil
            }
            guard let fingerprint = hibernationFingerprint(for: record),
                  fingerprint == confirmation.fingerprint else {
                confirmations.removeValue(forKey: record.key)
                return nil
            }
            let requestID = UUID()
            let inFlight = InFlightTeardown(
                requestID: requestID,
                terminalSurface: record.terminalPanel.surface
            )
            teardownInFlightByPanel[record.key] = inFlight
            confirmations.removeValue(forKey: record.key)
            return ConfirmedTeardownRequest(
                record: record,
                confirmationFingerprint: confirmation.fingerprint,
                effectiveLastActivityAt: effectiveLastActivityAt,
                requestID: requestID,
                inFlight: inFlight,
                epoch: teardownValidationEpochByPanel[record.key] ?? 0,
                generation: teardownValidationGeneration
            )
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
            fingerprint: fingerprint,
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

    private func clearTrackingState(cancelRestoreMonitors: Bool = false) {
        if cancelRestoreMonitors { cancelPostTeardownRestoreTasks() }
        teardownInFlightByPanel.values.forEach { $0.invalidate() }
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
        selectedKeys: Set<AgentHibernationPanelKey>
    ) {
        activityByPanel = activityByPanel.filter { currentKeys.contains($0.key) }
        terminalInputByPanel = terminalInputByPanel.filter { currentKeys.contains($0.key) }
        lifecycleChangeByPanel = lifecycleChangeByPanel.filter { currentKeys.contains($0.key) }
        teardownValidationEpochByPanel = teardownValidationEpochByPanel.filter { currentKeys.contains($0.key) }
        unableToProtectByPanel = unableToProtectByPanel.filter { currentKeys.contains($0.key) }
        teardownInFlightByPanel = teardownInFlightByPanel.filter { currentKeys.contains($0.key) }
        confirmations = confirmations.filter { key, _ in
            currentKeys.contains(key) && selectedKeys.contains(key)
        }
        tailFingerprintSamples = tailFingerprintSamples.filter { currentKeys.contains($0.key) }
    }

    func clearInFlightTeardown(_ key: AgentHibernationPanelKey, requestID: UUID) {
        guard teardownInFlightByPanel[key]?.requestID == requestID else { return }
        teardownInFlightByPanel[key]?.invalidate()
        teardownInFlightByPanel.removeValue(forKey: key)
    }
}
