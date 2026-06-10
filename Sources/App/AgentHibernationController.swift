import AppKit
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
    /// Present when the panel runs a restorable coding agent; nil for plain
    /// shells, which hibernate through the shell-restart mechanism instead.
    let agent: SessionRestorableAgentSnapshot?
    let lifecycle: AgentHibernationLifecycleState
    let hasUnconfirmedTerminalInput: Bool
    let lastActivityAt: TimeInterval
    let isProtected: Bool
    let isBusy: Bool
    let canRestartShell: Bool
    let workspaceUnmountedAt: TimeInterval?
    let hasLiveProcess: Bool
    let processIDs: Set<Int>

    var mechanism: SurfaceHibernationMechanism? {
        if agent != nil { return .agentResume }
        return canRestartShell ? .shellRestart : nil
    }
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
    private var surfaceSettingsObserver: NSObjectProtocol?
    private var defaultsObserver: NSObjectProtocol?
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
        surfaceSettingsObserver = NotificationCenter.default.addObserver(
            forName: SurfaceHibernationSettings.didChangeNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                AgentHibernationController.shared.updateTimerForCurrentSettings()
            }
        }
        // The Settings window writes the enabled keys straight to UserDefaults
        // without posting the dedicated change notifications, so reconcile the
        // timer on any defaults change as well; the reconcile is a cheap
        // idempotent read of two booleans.
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
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
        if let surfaceSettingsObserver {
            NotificationCenter.default.removeObserver(surfaceSettingsObserver)
            self.surfaceSettingsObserver = nil
        }
        if let defaultsObserver {
            NotificationCenter.default.removeObserver(defaultsObserver)
            self.defaultsObserver = nil
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
        let enabled = AgentHibernationSettings.isEnabled() || SurfaceHibernationSettings.isEnabled()
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
                let agentSettings = AgentHibernationSettings.values()
                let surfaceSettings = SurfaceHibernationSettings.values()
                guard agentSettings.enabled || surfaceSettings.enabled else { return }
                // The full index load is an expensive disk/process scan that
                // only the opt-in agent mechanism needs. Surface-only ticks
                // still recognize restored agent panels through the in-memory
                // workspace snapshots and protect running agents via the busy
                // gates instead.
                let index = agentSettings.enabled
                    ? await RestorableAgentSessionIndex.loadIncludingProcessDetectedSnapshots()
                    : .empty
                await MainActor.run {
                    AgentHibernationController.shared.evaluate(
                        index: index,
                        agentSettings: agentSettings,
                        surfaceSettings: surfaceSettings,
                        now: now
                    )
                }
            }
        }
        timer.resume()
        self.timer = timer
    }

    private func evaluate(
        index: RestorableAgentSessionIndex,
        agentSettings: AgentHibernationSettings.Values,
        surfaceSettings: SurfaceHibernationSettings.Values,
        now: Date
    ) {
        guard agentSettings.enabled || surfaceSettings.enabled else {
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
            (record.key, Self.isRecordLive(record))
        })
        let liveCount = isLiveByKey.values.filter { $0 }.count
        let liveRestorableCount = records.filter { record in
            record.agent != nil && (isLiveByKey[record.key] ?? false)
        }.count
        // Tail fingerprints detect output-only activity (a hidden build still
        // streaming) and cost a terminal text read per candidate, so only
        // maintain them while some rule could actually select panels.
        let agentCapPressure = agentSettings.enabled && liveRestorableCount >= agentSettings.maxLiveTerminals
        let surfaceCapPressure = surfaceSettings.enabled && liveCount >= surfaceSettings.maxLiveSurfaces
        let unmountedPressure = surfaceSettings.enabled && records.contains { record in
            guard let workspaceUnmountedAt = record.workspaceUnmountedAt else { return false }
            return nowTime - workspaceUnmountedAt >= surfaceSettings.unmountedIdleSeconds
        }
        let shouldMaintainTailSamples = agentCapPressure || surfaceCapPressure || unmountedPressure
        var inputsByKey: [AgentHibernationPanelKey: SurfaceHibernationPlannerInput] = [:]
        let plannerInputs = records.map { record -> SurfaceHibernationPlannerInput in
            var input = SurfaceHibernationPlannerInput(
                key: record.key,
                mechanism: record.mechanism,
                isLive: isLiveByKey[record.key] ?? false,
                isProtected: record.isProtected,
                isBusy: record.isBusy,
                lifecycle: record.lifecycle,
                hasUnconfirmedTerminalInput: record.hasUnconfirmedTerminalInput,
                lastActivityAt: record.lastActivityAt,
                workspaceUnmountedAt: record.workspaceUnmountedAt
            )
            if shouldMaintainTailSamples,
               input.isLive,
               SurfaceHibernationPlanner.isEvictable(input, agentSettings: agentSettings),
               let tailActivityAt = updateTailFingerprintSample(record: record, now: nowTime) {
                input.lastActivityAt = max(input.lastActivityAt, tailActivityAt)
            }
            inputsByKey[record.key] = input
            return input
        }
        let selectedKeys = SurfaceHibernationPlanner.selectedPanelKeys(
            inputs: plannerInputs,
            agentSettings: agentSettings,
            surfaceSettings: surfaceSettings,
            now: nowTime
        )
        let currentKeys = Set(records.map(\.key))
        pruneTrackingState(currentKeys: currentKeys, selectedKeys: selectedKeys)

        for record in records where selectedKeys.contains(record.key) {
            guard let input = inputsByKey[record.key] else { continue }
            evaluateConfirmation(
                record: record,
                input: input,
                agentSettings: agentSettings,
                surfaceSettings: surfaceSettings,
                now: nowTime
            )
        }
    }

    private static func isRecordLive(_ record: AgentHibernationRecord) -> Bool {
        (record.terminalPanel.surface.hasLiveSurface || (record.agent != nil && record.hasLiveProcess)) &&
            !record.terminalPanel.isAgentHibernated &&
            !record.terminalPanel.isSurfaceHibernated
    }

    private func evaluateConfirmation(
        record: AgentHibernationRecord,
        input: SurfaceHibernationPlannerInput,
        agentSettings: AgentHibernationSettings.Values,
        surfaceSettings: SurfaceHibernationSettings.Values,
        now: TimeInterval
    ) {
        guard input.isLive,
              SurfaceHibernationPlanner.isEvictable(input, agentSettings: agentSettings) else {
            confirmations.removeValue(forKey: record.key)
            return
        }

        if let confirmation = confirmations[record.key] {
            guard now >= confirmation.dueAt else { return }
            guard input.lastActivityAt <= confirmation.sampledAt else {
                confirmations.removeValue(forKey: record.key)
                return
            }
            guard let fingerprint = hibernationFingerprint(for: record),
                  fingerprint == confirmation.fingerprint else {
                confirmations.removeValue(forKey: record.key)
                return
            }
            confirmations.removeValue(forKey: record.key)
            hibernate(record: record, effectiveLastActivityAt: input.lastActivityAt)
            return
        }

        guard let fingerprint = hibernationFingerprint(for: record) else { return }
        let confirmationSeconds = record.agent != nil
            ? agentSettings.confirmationSeconds
            : surfaceSettings.confirmationSeconds
        confirmations[record.key] = Confirmation(
            fingerprint: fingerprint,
            sampledAt: now,
            dueAt: now + confirmationSeconds
        )
    }

    private func hibernate(record: AgentHibernationRecord, effectiveLastActivityAt: TimeInterval) {
        let lastActivityAt = Date(timeIntervalSince1970: effectiveLastActivityAt)
        if let agent = record.agent {
            terminateScopedProcessesForHibernation(record: record)
            record.workspace.enterAgentHibernation(
                panelId: record.key.panelId,
                agent: agent,
                lastActivityAt: lastActivityAt
            )
        } else {
            _ = record.workspace.enterSurfaceHibernation(
                panelId: record.key.panelId,
                lastActivityAt: lastActivityAt
            )
        }
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
        guard let agent = record.agent,
              record.hasLiveProcess,
              !record.terminalPanel.surface.hasLiveSurface else { return nil }
        return Self.processFallbackFingerprint(
            kind: agent.kind,
            sessionId: agent.sessionId,
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
                let workspaceUnmountedAt = workspaceIsVisible
                    ? nil
                    : workspace.portalRenderingDisabledAt?.timeIntervalSince1970
                for (panelId, panel) in workspace.panels {
                    guard let terminalPanel = panel as? TerminalPanel else {
                        continue
                    }
                    let agent = workspace.restorableAgentForHibernation(panelId: panelId, index: index)
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
                    let isRemoteTerminal = workspace.isRemoteWorkspace ||
                        workspace.isRemoteTerminalSurface(panelId)
                    // Recreating these surfaces would rerun startup commands,
                    // reattach remote PTYs, or drop queued input, so they are
                    // never shell-restarted.
                    let canRestartShell = agent == nil &&
                        !isRemoteTerminal &&
                        !terminalPanel.surface.hasDeferredStartupWorkForBackgroundStart()
                    // Busy means freeing the PTY could kill live work: not at a
                    // shell prompt, serving on a listening port, or — for
                    // shell-restart candidates — background jobs hanging off
                    // the prompt shell, which produce no prompt or output
                    // signal of their own.
                    let isBusy = terminalPanel.needsConfirmClose() ||
                        (canRestartShell &&
                            (!(workspace.surfaceListeningPorts[panelId] ?? []).isEmpty ||
                                terminalPanel.surface.foregroundProcessHasChildren()))
                    records.append(
                        AgentHibernationRecord(
                            key: key,
                            workspace: workspace,
                            terminalPanel: terminalPanel,
                            agent: agent,
                            lifecycle: lifecycle,
                            hasUnconfirmedTerminalInput: agent != nil && terminalInputAt > lifecycleChangeAt,
                            lastActivityAt: max(indexActivity, localActivity, createdAt),
                            isProtected: workspaceIsVisible && visiblePanelIds.contains(panelId),
                            isBusy: isBusy,
                            canRestartShell: canRestartShell,
                            workspaceUnmountedAt: workspaceUnmountedAt,
                            hasLiveProcess: index.hasLiveProcess(workspaceId: workspace.id, panelId: panelId),
                            processIDs: index.processIDs(workspaceId: workspace.id, panelId: panelId)
                        )
                    )
                }
            }
        }

        for context in mainWindowContexts.values {
            let visibleWorkspaceId = context.window?.isVisible == true ? context.tabManager.selectedTabId : nil
            visit(tabManager: context.tabManager, visibleWorkspaceId: visibleWorkspaceId)
        }
        if let tabManager {
            visit(tabManager: tabManager, visibleWorkspaceId: nil)
        }

        return records
    }
}
