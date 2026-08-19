import CmuxSidebar
import CmuxWorkspaces
import Foundation
import os

/// Main-actor owner for context pressure state and recovery actions across managed panes.
@MainActor
final class AgentContextManagementCoordinator {
    let policy = AgentContextInjectionPolicy()
    private let notificationCenter: NotificationCenter
    let settings: AgentContextManagementSettings
    var states: [UUID: PanelState] = [:]
    /// Input can arrive on the main actor before an output event's delivery
    /// task runs. Retain that cancellation edge so a late pressure event cannot
    /// authorize automation after the user already took the keyboard.
    var userInputObservedBeforePressure: Set<UUID> = []
    static let logger = Logger(subsystem: "com.cmuxterm.app", category: "AgentContextManagement")
    private var settingsObserver: NSObjectProtocol?
    private var userDefaultsObserver: NSObjectProtocol?

    init(
        notificationCenter: NotificationCenter = .default,
        defaults: UserDefaults = .standard
    ) {
        self.notificationCenter = notificationCenter
        self.settings = AgentContextManagementSettings(
            defaults: defaults,
            notificationCenter: notificationCenter
        )
        settingsObserver = notificationCenter.addObserver(
            forName: AgentContextManagementSettings.didChangeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Self.deliverOnMainActor { [weak self] in
                self?.reevaluateAll()
            }
        }
        // Settings UI writes go through UserDefaultsSettingsStore, while
        // cmux.json import and older callers write UserDefaults directly.
        // Observe both paths so the coordinator always uses the committed
        // setting values without requiring each caller to know this feature.
        userDefaultsObserver = notificationCenter.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Self.deliverOnMainActor { [weak self] in
                self?.reevaluateAll()
            }
        }
    }

    deinit {
        if let settingsObserver {
            notificationCenter.removeObserver(settingsObserver)
        }
        if let userDefaultsObserver {
            notificationCenter.removeObserver(userDefaultsObserver)
        }
    }

    /// Receives a detector event from the serialized PTY tee callback.
    func handle(
        event: AgentContextPressureEvent,
        workspaceID: UUID,
        surfaceID: UUID,
        detectorGeneration: UInt64 = 0
    ) {
        handle(
            events: [event],
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            detectorGeneration: detectorGeneration
        )
    }

    /// Coalesces all detector events from one PTY chunk before evaluating the
    /// injection policy. A warning can contain multiple provider signals; a
    /// single chunk must never cause two recovery commands to race each other.
    func handle(
        events: [AgentContextPressureEvent],
        workspaceID: UUID,
        surfaceID: UUID,
        detectorGeneration: UInt64 = 0
    ) {
        guard !events.isEmpty else { return }
        guard let owner = owner(for: surfaceID, preferredWorkspaceID: workspaceID),
        let binding = owner.binding(panelId: surfaceID),
        let provider = AgentContextProvider(managedAgentKind: binding.kind) else {
            for event in events {
                structuredLog(
                    "detection.ignored",
                    workspaceID: workspaceID,
                    surfaceID: surfaceID,
                    detail: "provider=\(event.provider.rawValue) signal=\(event.signal.rawValue) occurrence=\(event.occurrence) reason=unmanaged"
                )
            }
            return
        }

        let matchingEvents = events.filter { event in
            guard provider == event.provider else {
                structuredLog(
                    "detection.ignored",
                    workspaceID: workspaceID,
                    surfaceID: surfaceID,
                    detail: "provider-mismatch expected=\(provider.rawValue) observed=\(event.provider.rawValue) signal=\(event.signal.rawValue) occurrence=\(event.occurrence)"
                )
                return false
            }
            return true
        }
        guard !matchingEvents.isEmpty else { return }

        // Record every provider event before any generation or lifecycle gate
        // can discard it. The ignored reason is logged separately below.
        for event in matchingEvents {
            structuredLog(
                "detection",
                workspaceID: owner.workspaceID,
                surfaceID: surfaceID,
                detail: "provider=\(provider.rawValue) signal=\(event.signal.rawValue) occurrence=\(event.occurrence)"
            )
        }

        let currentBinding = binding
        let currentDetectorGeneration = owner.contextPressureDetectorGeneration(panelId: surfaceID)
        guard detectorGeneration >= currentDetectorGeneration else {
            structuredLog(
                "detection.ignored",
                workspaceID: owner.workspaceID,
                surfaceID: surfaceID,
                detail: "stale-runtime-generation observed=\(detectorGeneration) expected=\(currentDetectorGeneration)"
            )
            return
        }
        let stateForBinding = states[surfaceID]
        var state: PanelState
        if let stateForBinding,
           stateForBinding.provider == provider,
           sameSession(stateForBinding.binding, currentBinding) {
            state = stateForBinding
            guard detectorGeneration >= state.detectorGeneration else {
                structuredLog(
                    "detection.ignored",
                    workspaceID: owner.workspaceID,
                    surfaceID: surfaceID,
                    detail: "stale-detector-generation observed=\(detectorGeneration) expected=\(state.detectorGeneration)"
                )
                return
            }
            state.detectorGeneration = max(
                state.detectorGeneration,
                currentDetectorGeneration,
                detectorGeneration
            )
        } else if stateForBinding == nil {
            state = makePanelState(
                panelId: surfaceID,
                provider: provider,
                binding: currentBinding,
                owner: owner,
                detectorGeneration: max(currentDetectorGeneration, detectorGeneration),
                userInputObserved: userInputObservedBeforePressure.contains(surfaceID)
            )
            states[surfaceID] = state
            structuredLog(
                "detection.state-created",
                workspaceID: owner.workspaceID,
                surfaceID: surfaceID,
                detail: "runtime-generation=\(detectorGeneration)"
            )
        } else {
            // A panel id can be reused for a replacement managed session. Do
            // not let an output event from that handoff seed state until the
            // authoritative binding callback has reset the detector.
            let expectedGeneration = owner.resetContextPressureDetector(panelId: surfaceID)
            structuredLog(
                "detection.ignored",
                workspaceID: owner.workspaceID,
                surfaceID: surfaceID,
                detail: "untracked-binding observed=\(detectorGeneration) expected=\(expectedGeneration)"
            )
            return
        }
        // A shell callback can create coordinator state before the provider's
        // lifecycle callback is delivered. Seed that one missing piece from
        // the authoritative owner map when no provider evidence is retained.
        if state.lifecycleByKey.isEmpty {
            let evidence = owner.lifecycleEvidence(panelId: surfaceID, provider: provider)
            if !evidence.isEmpty {
                state.lifecycleByKey = evidence
                state.lifecycle = Self.effectiveLifecycle(from: evidence.values)
                state.dialogOpen = state.lifecycle == .needsInput
            }
        }
        state.binding = currentBinding
        state.userInputObserved = state.userInputObserved
            || userInputObservedBeforePressure.contains(surfaceID)
        // The user owns the current input episode. Output produced while that
        // turn is in flight must not recreate the pressure episode that the
        // user's keystroke cancelled; the detector is re-armed at the next
        // authoritative idle boundary.
        guard !state.userInputObserved else {
            structuredLog(
                "detection.ignored",
                workspaceID: owner.workspaceID,
                surfaceID: surfaceID,
                detail: "user-input-observed"
            )
            states[surfaceID] = state
            return
        }
        // A compact/clear command can itself produce auto-compaction output.
        // Do not let that output recursively authorize another command; wait
        // for the provider's next authoritative running-to-idle turn boundary.
        guard !state.recoveryAwaitingLifecycleBoundary else {
            structuredLog(
                "detection.ignored",
                workspaceID: owner.workspaceID,
                surfaceID: surfaceID,
                detail: "recovery-awaiting-lifecycle-boundary"
            )
            states[surfaceID] = state
            return
        }
        let pressureWasActive = state.pressure.isUnderPressure
        let previousSignals = Set(state.pressure.detectedSignals)
        var signals = state.pressure.detectedSignals
        var occurrences = state.pressure.occurrences
        for event in matchingEvents {
            if !signals.contains(event.signal) { signals.append(event.signal) }
            occurrences[event.signal] = max(occurrences[event.signal, default: 0], event.occurrence)
        }
        state.pressure = AgentContextPressureSnapshot(
            isUnderPressure: true,
            detectedSignals: signals,
            occurrences: occurrences
        )
        states[surfaceID] = state
        owner.setPressureStatus(SidebarStatusEntry(
            key: Self.statusKey(for: surfaceID),
            value: String(localized: "sidebar.agentContext.pressure", defaultValue: "Context pressure detected"),
            icon: "exclamationmark.triangle.fill",
            color: "#D97706",
            priority: 20
        ), key: Self.statusKey(for: surfaceID), panelId: surfaceID)
        if !pressureWasActive || matchingEvents.contains(where: { !previousSignals.contains($0.signal) }) {
            owner.appendPressureLog()
        }
        evaluate(surfaceID: surfaceID, owner: owner)
    }

    /// Receives authoritative lifecycle updates from managed-agent hooks.
    func updateLifecycle(
        _ lifecycle: AgentContextLifecycleState,
        key: String,
        panelId: UUID
    ) {
        guard let owner = owner(for: panelId, preferredWorkspaceID: nil),
              let binding = owner.binding(panelId: panelId),
              let provider = AgentContextProvider(managedAgentKind: binding.kind) else {
            resetForUnboundSession(panelId: panelId)
            return
        }
        guard AgentContextProvider(managedAgentKind: key) == provider else {
            structuredLog(
                "lifecycle.ignored",
                workspaceID: owner.workspaceID,
                surfaceID: panelId,
                detail: "provider-mismatch key=\(key) bound=\(provider.rawValue)"
            )
            // Feed and other attention owners use their own lifecycle keys.
            // They do not replace the provider's idle/running evidence, but a
            // needs-input value still opens a dialog and must immediately
            // re-evaluate any pending recovery.
            if states[panelId]?.pressure.isUnderPressure == true {
                evaluate(surfaceID: panelId, owner: owner)
            }
            return
        }
        let existingState = states[panelId]
        let stateGeneration: UInt64
        if let existingState,
           existingState.provider == provider,
           sameSession(existingState.binding, binding) {
            stateGeneration = existingState.detectorGeneration
        } else if existingState == nil {
            // Lifecycle evidence can be the first coordinator signal. Do not
            // reset a live detector here or a pressure event already queued
            // for this runtime would be rejected as stale.
            stateGeneration = owner.contextPressureDetectorGeneration(panelId: panelId)
        } else {
            stateGeneration = owner.resetContextPressureDetector(panelId: panelId)
        }
        var state = existingState
            .flatMap { existing in
                existing.provider == provider && sameSession(existing.binding, binding)
                    ? existing
                    : nil
            }
            ?? makePanelState(
                panelId: panelId,
                provider: provider,
                binding: binding,
                owner: owner,
                detectorGeneration: stateGeneration,
                seedLifecycleEvidence: existingState == nil
            )
        state.userInputObserved = state.userInputObserved
            || userInputObservedBeforePressure.contains(panelId)
        let previousLifecycle = state.lifecycle
        state.binding = binding
        state.lifecycleByKey[key] = lifecycle
        state.lifecycle = Self.effectiveLifecycle(from: state.lifecycleByKey.values)
        state.dialogOpen = state.lifecycle == .needsInput
        if state.preservationAwaitingAcknowledgement, state.lifecycle == .running {
            state.preservationObservedRunning = true
        }
        if state.preservationAwaitingAcknowledgement,
           state.preservationObservedRunning,
           state.lifecycle == .idle {
            state.preservationAwaitingAcknowledgement = false
            state.preservationObservedRunning = false
            state.preservationCompleted = true
            structuredLog("preservation.acknowledged", workspaceID: owner.workspaceID, surfaceID: panelId, detail: "lifecycle-idle")
        }
        if state.recoveryAwaitingLifecycleBoundary, state.lifecycle == .running {
            state.recoveryObservedRunning = true
        }
        if state.recoveryAwaitingLifecycleBoundary,
           state.recoveryObservedRunning,
           state.lifecycle == .idle {
            state.recoveryAwaitingLifecycleBoundary = false
            state.recoveryObservedRunning = false
            structuredLog("recovery.rearmed", workspaceID: owner.workspaceID, surfaceID: panelId, detail: "lifecycle-idle")
        }
        if (previousLifecycle == .running || previousLifecycle == .needsInput),
           state.lifecycle == .idle,
           state.userInputObserved {
            // A user turn has now completed. Discard any output that arrived
            // during it and reset the serialized tee before considering new
            // pressure at the fresh prompt.
            state.pressure = AgentContextPressureSnapshot()
            let resetGeneration = owner.resetContextPressureDetector(panelId: panelId)
            state.detectorGeneration = max(state.detectorGeneration, resetGeneration)
            state.userInputObserved = false
            state.unsafeClearNotificationSent = false
            userInputObservedBeforePressure.remove(panelId)
            owner.clearPressureStatus(key: Self.statusKey(for: panelId), panelId: panelId)
            structuredLog(
                "user-input-rearmed",
                workspaceID: owner.workspaceID,
                surfaceID: panelId,
                detail: "lifecycle-idle"
            )
        }
        states[panelId] = state
        evaluate(surfaceID: panelId, owner: owner)
    }

    /// Receives shell prompt state without requiring the shell to be idle for a TUI agent.
    func updateShell(_ shellActivity: PanelShellActivityState, panelId: UUID) {
        guard let owner = owner(for: panelId, preferredWorkspaceID: nil),
              let binding = owner.binding(panelId: panelId),
              let provider = AgentContextProvider(managedAgentKind: binding.kind) else {
            resetForUnboundSession(panelId: panelId)
            return
        }
        let existingState = states[panelId]
        let stateGeneration: UInt64
        if let existingState,
           existingState.provider == provider,
           sameSession(existingState.binding, binding) {
            stateGeneration = existingState.detectorGeneration
        } else if existingState == nil {
            stateGeneration = owner.contextPressureDetectorGeneration(panelId: panelId)
        } else {
            stateGeneration = owner.resetContextPressureDetector(panelId: panelId)
        }
        var state = existingState
            .flatMap { existing in
                existing.provider == provider && sameSession(existing.binding, binding)
                    ? existing
                    : nil
            }
            ?? makePanelState(
                panelId: panelId,
                provider: provider,
                binding: binding,
                owner: owner,
                detectorGeneration: stateGeneration,
                seedLifecycleEvidence: existingState == nil
            )
        state.userInputObserved = state.userInputObserved
            || userInputObservedBeforePressure.contains(panelId)
        state.binding = binding
        state.shellActivity = shellActivity
        states[panelId] = state
        evaluate(surfaceID: panelId, owner: owner)
    }

    /// Removes all state and sidebar artifacts for a closed panel. Transfers
    /// can retain the session state while dropping the source owner's sidebar
    /// entry; the destination reattaches that entry after publishing its
    /// binding.
    func remove(panelId: UUID, workspace: Workspace?, preserveState: Bool = false) {
        if !preserveState {
            states.removeValue(forKey: panelId)
            userInputObservedBeforePressure.remove(panelId)
        }
        if let workspace {
            workspace.statusEntries.removeValue(forKey: Self.statusKey(for: panelId))
        } else if let owner = owner(for: panelId, preferredWorkspaceID: nil) {
            owner.clearPressureStatus(key: Self.statusKey(for: panelId), panelId: panelId)
        }
    }

    static func statusKey(for panelId: UUID) -> String {
        "agent.context_health.\(panelId.uuidString)"
    }

    func structuredLog(
        _ event: String,
        workspaceID: UUID?,
        surfaceID: UUID,
        detail: String
    ) {
        let line = "agent.context.\(event) workspace=\(workspaceID?.uuidString ?? "nil") surface=\(surfaceID.uuidString) \(detail)"
        Self.logger.info("\(line, privacy: .public)")
#if DEBUG
        cmuxDebugLog(line)
#endif
    }

    func shellDidChange(panelId: UUID, state: PanelShellActivityState) {
        updateShell(state, panelId: panelId)
    }

    /// Called when lifecycle evidence is removed. Unknown is intentional:
    /// stale `.idle` evidence must not authorize a destructive command.
    func lifecycleDidClear(key: String? = nil, panelId: UUID) {
        guard var state = states[panelId] else { return }
        if let key {
            guard AgentContextProvider(managedAgentKind: key) == state.provider else {
                if let owner = owner(for: panelId, preferredWorkspaceID: nil),
                   state.pressure.isUnderPressure {
                    evaluate(surfaceID: panelId, owner: owner)
                }
                return
            }
            state.lifecycleByKey.removeValue(forKey: key)
        } else {
            state.lifecycleByKey.removeAll(keepingCapacity: true)
        }
        state.lifecycle = Self.effectiveLifecycle(from: state.lifecycleByKey.values)
        state.dialogOpen = state.lifecycle == .needsInput
        if state.lifecycle == .unknown {
            state.preservationAwaitingAcknowledgement = false
            state.preservationObservedRunning = false
            state.preservationCompleted = false
            state.recoveryAwaitingLifecycleBoundary = false
            state.recoveryObservedRunning = false
        }
        states[panelId] = state
        if let owner = owner(for: panelId, preferredWorkspaceID: nil) {
            evaluate(surfaceID: panelId, owner: owner)
        }
    }

    private func reevaluateAll() {
        // Evaluation can invalidate a binding and remove its state. Iterate a
        // snapshot so fail-closed cleanup never mutates the dictionary being
        // traversed.
        for panelId in Array(states.keys) {
            guard let owner = owner(for: panelId, preferredWorkspaceID: nil) else { continue }
            evaluate(surfaceID: panelId, owner: owner)
        }
    }

    nonisolated private static func deliverOnMainActor(
        _ action: @escaping @MainActor @Sendable () -> Void
    ) {
        Task { @MainActor in action() }
    }

}
