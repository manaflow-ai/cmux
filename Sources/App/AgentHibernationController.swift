import AppKit
import Darwin
import Foundation

struct AgentHibernationPanelKey: Hashable, Sendable {
    let workspaceId: UUID
    let panelId: UUID
}

struct AgentHibernationPlannerInput: Sendable {
    let key: AgentHibernationPanelKey
    let hasRestorableAgent: Bool
    let isLive: Bool
    let isProtected: Bool
    let lifecycle: AgentHibernationLifecycleState
    let hasUnconfirmedTerminalInput: Bool
    let lastActivityAt: TimeInterval
}

enum AgentHibernationPlanner {
    static func selectedPanelKeys(
        inputs: [AgentHibernationPlannerInput],
        settings: AgentHibernationSettings.Values,
        now: TimeInterval
    ) -> Set<AgentHibernationPanelKey> {
        guard settings.enabled else { return [] }
        let liveRestorable = inputs.filter { $0.hasRestorableAgent && $0.isLive }
        let excess = liveRestorable.count - settings.maxLiveTerminals
        guard excess > 0 else { return [] }

        let eligible = liveRestorable
            .filter { input in
                !input.isProtected &&
                    input.lifecycle.allowsHibernation &&
                    !input.hasUnconfirmedTerminalInput &&
                    now - input.lastActivityAt >= settings.idleSeconds
            }
            .sorted { lhs, rhs in
                if lhs.lastActivityAt == rhs.lastActivityAt {
                    return lhs.key.panelId.uuidString < rhs.key.panelId.uuidString
                }
                return lhs.lastActivityAt < rhs.lastActivityAt
            }

        return Set(eligible.prefix(excess).map(\.key))
    }
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
    let processIDs: Set<Int>
}

@MainActor
final class AgentHibernationController {
    static let shared = AgentHibernationController()

    private struct Confirmation {
        let fingerprint: String
        let sampledAt: TimeInterval
        let dueAt: TimeInterval
    }

    private struct TailFingerprintSample {
        let fingerprint: String
        let stableSince: TimeInterval
    }

    private let timerQueue = DispatchQueue(label: "com.cmux.agent-hibernation", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var settingsObserver: NSObjectProtocol?
    private var activityByPanel: [AgentHibernationPanelKey: TimeInterval] = [:]
    private var terminalInputByPanel: [AgentHibernationPanelKey: TimeInterval] = [:]
    private var lifecycleChangeByPanel: [AgentHibernationPanelKey: TimeInterval] = [:]
    private var confirmations: [AgentHibernationPanelKey: Confirmation] = [:]
    private var tailFingerprintSamples: [AgentHibernationPanelKey: TailFingerprintSample] = [:]

    private init() {}

    func start() {
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
                AgentHibernationController.shared.updateTimerForCurrentSettings()
            }
        }
        updateTimerForCurrentSettings()
    }

    func stop() {
        timer?.cancel()
        timer = nil
        AgentHibernationTrackingGate.setEnabled(false)
        clearTrackingState()
        if let settingsObserver {
            NotificationCenter.default.removeObserver(settingsObserver)
            self.settingsObserver = nil
        }
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

    @discardableResult
    private func recordActivity(workspaceId: UUID, panelId: UUID, recordedAt: Date) -> AgentHibernationPanelKey {
        let key = AgentHibernationPanelKey(workspaceId: workspaceId, panelId: panelId)
        activityByPanel[key] = recordedAt.timeIntervalSince1970
        confirmations.removeValue(forKey: key)
        return key
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
            Task.detached(priority: .utility) {
                let index = await RestorableAgentSessionIndex.loadIncludingProcessDetectedSnapshots()
                await MainActor.run {
                    let settings = AgentHibernationSettings.values()
                    guard settings.enabled else { return }
                    AgentHibernationController.shared.evaluate(index: index, settings: settings, now: now)
                }
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
            if shouldMaintainTailSamples,
               isLive,
               !record.isProtected,
               record.lifecycle.allowsHibernation,
               !record.hasUnconfirmedTerminalInput,
               let tailActivityAt = updateTailFingerprintSample(record: record, now: nowTime) {
                effectiveLastActivityAt = max(record.lastActivityAt, tailActivityAt)
            }
            effectiveActivityByKey[record.key] = effectiveLastActivityAt
            return AgentHibernationPlannerInput(
                key: record.key,
                hasRestorableAgent: true,
                isLive: isLive,
                isProtected: record.isProtected,
                lifecycle: record.lifecycle,
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

        for record in records where selectedKeys.contains(record.key) {
            evaluateConfirmation(
                record: record,
                effectiveLastActivityAt: effectiveActivityByKey[record.key] ?? record.lastActivityAt,
                settings: settings,
                now: nowTime
            )
        }
    }

    private func evaluateConfirmation(
        record: AgentHibernationRecord,
        effectiveLastActivityAt: TimeInterval,
        settings: AgentHibernationSettings.Values,
        now: TimeInterval
    ) {
        guard record.lifecycle.allowsHibernation,
              !record.hasUnconfirmedTerminalInput,
              !record.isProtected,
              record.terminalPanel.surface.hasLiveSurface || record.hasLiveProcess,
              !record.terminalPanel.isAgentHibernated else {
            confirmations.removeValue(forKey: record.key)
            return
        }

        if let confirmation = confirmations[record.key] {
            guard now >= confirmation.dueAt else { return }
            guard effectiveLastActivityAt <= confirmation.sampledAt else {
                confirmations.removeValue(forKey: record.key)
                return
            }
            guard let fingerprint = hibernationFingerprint(for: record),
                  fingerprint == confirmation.fingerprint else {
                confirmations.removeValue(forKey: record.key)
                return
            }
            confirmations.removeValue(forKey: record.key)
            terminateScopedProcessesForHibernation(record: record)
            record.workspace.enterAgentHibernation(
                panelId: record.key.panelId,
                agent: record.agent,
                lastActivityAt: Date(timeIntervalSince1970: effectiveLastActivityAt)
            )
            return
        }

        guard let fingerprint = hibernationFingerprint(for: record) else { return }
        confirmations[record.key] = Confirmation(
            fingerprint: fingerprint,
            sampledAt: now,
            dueAt: now + settings.confirmationSeconds
        )
    }

    private func updateTailFingerprintSample(
        record: AgentHibernationRecord,
        now: TimeInterval
    ) -> TimeInterval? {
        guard !record.terminalPanel.isAgentHibernated,
              record.terminalPanel.surface.hasLiveSurface || record.hasLiveProcess,
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

    private func hibernationFingerprint(for record: AgentHibernationRecord) -> String? {
        if let tail = tailFingerprint(for: record.terminalPanel) {
            return Self.scrollbackFingerprint(tail: tail, processIDs: record.processIDs)
        }
        guard record.hasLiveProcess,
              !record.terminalPanel.surface.hasLiveSurface else { return nil }
        return Self.processFallbackFingerprint(
            kind: record.agent.kind,
            sessionId: record.agent.sessionId,
            processIDs: record.processIDs
        )
    }

    nonisolated static func scrollbackFingerprint(tail: String, processIDs: Set<Int>) -> String {
        "scrollback:\(processIdentityFingerprint(processIDs)):\(tail)"
    }

    nonisolated static func processFallbackFingerprint(
        kind: RestorableAgentKind,
        sessionId: String,
        processIDs: Set<Int>
    ) -> String {
        "process:\(kind.rawValue):\(sessionId):\(processIdentityFingerprint(processIDs))"
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

    private func terminateScopedProcessesForHibernation(record: AgentHibernationRecord) {
        guard !record.processIDs.isEmpty else { return }
        let currentProcessID = getpid()
        let currentProcessGroupID = getpgrp()
        var signaledProcessGroups: Set<pid_t> = []
        for rawPID in record.processIDs.sorted(by: >) {
            guard rawPID > 0, rawPID <= Int(Int32.max) else { continue }
            let pid = pid_t(rawPID)
            guard pid != currentProcessID else { continue }
            guard let process = CmuxTopProcessSnapshot.processArgumentsAndEnvironment(for: rawPID),
                  process.matchesCMUXScope(workspaceId: record.key.workspaceId, surfaceId: record.key.panelId) else {
                continue
            }
            let processGroupID = getpgid(pid)
            if processGroupID > 1,
               processGroupID != currentProcessGroupID,
               signaledProcessGroups.insert(processGroupID).inserted {
                _ = kill(-processGroupID, SIGTERM)
            }
            _ = kill(pid, SIGTERM)
        }
    }

    private func clearTrackingState() {
        activityByPanel.removeAll(keepingCapacity: false)
        terminalInputByPanel.removeAll(keepingCapacity: false)
        lifecycleChangeByPanel.removeAll(keepingCapacity: false)
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
        confirmations = confirmations.filter { key, _ in
            currentKeys.contains(key) && selectedKeys.contains(key)
        }
        tailFingerprintSamples = tailFingerprintSamples.filter { currentKeys.contains($0.key) }
    }
}

extension AppDelegate {
    @MainActor
    func agentHibernationRecords(
        index: RestorableAgentSessionIndex,
        activityByPanel: [AgentHibernationPanelKey: TimeInterval],
        terminalInputByPanel: [AgentHibernationPanelKey: TimeInterval],
        lifecycleChangeByPanel: [AgentHibernationPanelKey: TimeInterval]
    ) -> [AgentHibernationRecord] {
        var records: [AgentHibernationRecord] = []
        var seenManagers: Set<ObjectIdentifier> = []

        func visit(tabManager manager: TabManager, visibleWorkspaceId: UUID?) {
            let managerId = ObjectIdentifier(manager)
            guard seenManagers.insert(managerId).inserted else { return }
            for workspace in manager.tabs {
                let workspaceIsVisible = visibleWorkspaceId == workspace.id
                let visiblePanelIds = workspaceIsVisible
                    ? workspace.agentHibernationVisiblePanelIdsForCurrentLayout()
                    : []
                for (panelId, panel) in workspace.panels {
                    guard let terminalPanel = panel as? TerminalPanel,
                          let agent = workspace.restorableAgentForHibernation(panelId: panelId, index: index) else {
                        continue
                    }
                    let key = AgentHibernationPanelKey(workspaceId: workspace.id, panelId: panelId)
                    let indexActivity = index.updatedAt(workspaceId: workspace.id, panelId: panelId) ?? 0
                    let localActivity = activityByPanel[key] ?? 0
                    let terminalInputAt = terminalInputByPanel[key] ?? 0
                    let lifecycleChangeAt = lifecycleChangeByPanel[key] ?? 0
                    let createdAt = terminalPanel.surface.debugRuntimeSurfaceCreatedAt()?.timeIntervalSince1970
                        ?? terminalPanel.surface.debugCreatedAt().timeIntervalSince1970
                    let lifecycle = workspace.agentHibernationLifecycleState(
                        panelId: panelId,
                        fallback: index.lifecycle(workspaceId: workspace.id, panelId: panelId)
                    )
                    records.append(
                        AgentHibernationRecord(
                            key: key,
                            workspace: workspace,
                            terminalPanel: terminalPanel,
                            agent: agent,
                            lifecycle: lifecycle,
                            hasUnconfirmedTerminalInput: terminalInputAt > lifecycleChangeAt,
                            lastActivityAt: max(indexActivity, localActivity, createdAt),
                            isProtected: workspaceIsVisible && visiblePanelIds.contains(panelId),
                            hasLiveProcess: index.hasLiveProcess(workspaceId: workspace.id, panelId: panelId),
                            processIDs: index.processIDs(workspaceId: workspace.id, panelId: panelId)
                        )
                    )
                }
            }
        }

        for context in registeredMainWindows {
            let visibleWorkspaceId = context.window?.isVisible == true ? context.tabManager.selectedTabId : nil
            visit(tabManager: context.tabManager, visibleWorkspaceId: visibleWorkspaceId)
        }
        if let tabManager {
            visit(tabManager: tabManager, visibleWorkspaceId: nil)
        }

        return records
    }
}
