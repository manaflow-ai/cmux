import CmuxSidebar
import CmuxWorkspaces
import Foundation
import os

/// Main-actor owner for context pressure state and recovery actions across managed panes.
@MainActor
final class AgentContextManagementCoordinator {
    /// Weak panel-to-owner references keep lifecycle lookups bounded without
    /// retaining workspaces or Dock stores past their owning window.
    final class WeakPanelOwnerReference {
        weak var workspace: Workspace?
        weak var dock: DockSplitStore?

        init(owner: PanelOwner) {
            switch owner {
            case .workspace(let workspace):
                self.workspace = workspace
            case .dock(let dock):
                self.dock = dock
            }
        }

        var resolved: PanelOwner? {
            if let workspace {
                return .workspace(workspace)
            }
            if let dock {
                return .dock(dock)
            }
            return nil
        }
    }

    let policy = AgentContextInjectionPolicy()
    let handoffVerifier: AgentContextHandoffVerifier
    private let notificationCenter: NotificationCenter
    let settings: AgentContextManagementSettings
    var states: [UUID: PanelState] = [:]
    /// One cancellable baseline/verification task per panel; user input and
    /// teardown cancel both before either result can mutate a new session.
    var preservationPreparationTasks: [UUID: Task<Void, Never>] = [:]
    var preservationVerificationTasks: [UUID: Task<Void, Never>] = [:]
    var preservationVerificationRequestedAtByPanel: [UUID: Date] = [:]
    /// Input can arrive on the main actor before an output event's delivery
    /// task runs. Retain that cancellation edge so a late pressure event cannot
    /// authorize automation after the user already took the keyboard.
    var userInputObservedBeforePressure: Set<UUID> = []
    /// Derived ownership index used by settings-wide reevaluation. Entries are
    /// weak and are invalidated whenever a panel leaves its current owner.
    var ownerReferencesByPanelID: [UUID: WeakPanelOwnerReference] = [:]
    static let logger = Logger(subsystem: "com.cmuxterm.app", category: "AgentContextManagement")
    private var settingsObserver: NSObjectProtocol?
    private var userDefaultsObserver: NSObjectProtocol?
    private var pendingReevaluationTask: Task<Void, Never>?
    private var pendingForcedReevaluation = false

    private struct SettingsSnapshot: Equatable {
        let enabled: Bool
        let action: AgentContextInjectionAction
        let preservesState: Bool

        init(settings: AgentContextManagementSettings) {
            enabled = settings.isEnabled
            action = settings.action
            preservesState = settings.preservesState
        }
    }

    private var lastSettingsSnapshot: SettingsSnapshot?

    init(
        notificationCenter: NotificationCenter = .default,
        defaults: UserDefaults = .standard,
        handoffVerifier: AgentContextHandoffVerifier = AgentContextHandoffVerifier()
    ) {
        self.notificationCenter = notificationCenter
        self.handoffVerifier = handoffVerifier
        self.settings = AgentContextManagementSettings(
            defaults: defaults,
            notificationCenter: notificationCenter
        )
        self.lastSettingsSnapshot = SettingsSnapshot(settings: settings)
        settingsObserver = notificationCenter.addObserver(
            forName: AgentContextManagementSettings.didChangeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Self.deliverOnMainActor { [weak self] in
                self?.scheduleReevaluation(force: true)
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
                self?.scheduleReevaluation(force: false)
            }
        }
    }

    deinit {
        preservationPreparationTasks.values.forEach { $0.cancel() }
        preservationVerificationTasks.values.forEach { $0.cancel() }
        pendingReevaluationTask?.cancel()
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

        owner.setContextPressureMonitoringEnabled(
            panelId: surfaceID,
            // Keep provider detection/reporting active even when the user has
            // disabled automated writes. The policy's `enabled` input gates
            // injection separately below.
            enabled: true
        )
        owner.setContextPressureProvider(panelId: surfaceID, provider: provider)

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
        if !Self.providerEvidenceIsFresh(state.providerEvidenceReceivedAt) {
            state.providerEvidenceConfirmed = false
            state.providerEvidenceReceivedAt = nil
        }
        if !pressureWasActive {
            // A provider event from an earlier episode must not authorize a
            // fresh textual marker. A still-fresh hook may have arrived just
            // before the marker; its bounded receipt window is retained.
            state.unsafeClearNotificationSent = false
        }
        for event in matchingEvents {
            if !signals.contains(event.signal) { signals.append(event.signal) }
            occurrences[event.signal] = max(occurrences[event.signal, default: 0], event.occurrence)
        }
        state.pressure = AgentContextPressureSnapshot(
            isUnderPressure: true,
            detectedSignals: signals,
            occurrences: occurrences
        )
        state.pressureConfirmation.observePressure(
            isNewEpisode: !pressureWasActive,
            lifecycle: state.lifecycle
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

    /// Removes all state and sidebar artifacts for a closed panel. Transfers
    /// can retain the session state while dropping the source owner's sidebar
    /// entry; the destination reattaches that entry after publishing its
    /// binding.
    func remove(
        panelId: UUID,
        workspace: Workspace?,
        preserveState: Bool = false,
        ownerOverride: PanelOwner? = nil
    ) {
        let currentOwner = ownerOverride ?? owner(
            for: panelId,
            preferredWorkspaceID: workspace?.id
        )
        currentOwner?.setContextPressureMonitoringEnabled(
            panelId: panelId,
            enabled: false
        )
        currentOwner?.setContextPressureProvider(panelId: panelId, provider: nil)
        // A transfer invalidates any in-flight preflight or verification task;
        // the destination must publish its binding before recovery can resume.
        cancelPreservationVerification(panelId: panelId)
        if preserveState {
            // Transfer keeps the pressure snapshot, but destination shell
            // callbacks must not reuse source-owner lifecycle confirmation
            // before the destination binding fence is published.
            if var state = states[panelId] {
                state.pressureConfirmation.reset()
                state.providerEvidenceConfirmed = false
                state.providerEvidenceReceivedAt = nil
                state.preservationPreparationInFlight = false
                state.preservationBaseline = nil
                state.preservationHandoffPath = nil
                state.preservationRequestedAt = nil
                state.preservationAwaitingAcknowledgement = false
                state.preservationObservedRunning = false
                state.preservationVerificationInFlight = false
                states[panelId] = state
            }
        } else {
            ownerReferencesByPanelID.removeValue(forKey: panelId)
            states.removeValue(forKey: panelId)
            userInputObservedBeforePressure.remove(panelId)
        }
        if let workspace {
            workspace.statusEntries.removeValue(forKey: Self.statusKey(for: panelId))
        } else if let owner = currentOwner {
            owner.clearPressureStatus(key: Self.statusKey(for: panelId), panelId: panelId)
        }
    }

    /// Drops coordinator state for several panels already owned by one
    /// Workspace or Dock, avoiding a global owner lookup for each panel.
    func remove(panelIds: [UUID], owner: PanelOwner) {
        for panelId in panelIds {
            remove(
                panelId: panelId,
                workspace: nil,
                ownerOverride: owner
            )
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

    private func reevaluateAll() {
        // Resolve each owner once. `owner(for:)` is backed by a weak panel
        // index, so a settings change is O(P) rather than scanning every Dock
        // for every panel (O(P×D)). Evaluation can invalidate a binding and
        // remove its state, so iterate snapshots and group by owner.
        var groupedOwners: [ObjectIdentifier: (owner: PanelOwner, panelIDs: [UUID])] = [:]
        for panelId in Array(states.keys) {
            guard let owner = owner(for: panelId, preferredWorkspaceID: nil) else {
                ownerReferencesByPanelID.removeValue(forKey: panelId)
                continue
            }
            let ownerID = owner.identity
            groupedOwners[ownerID, default: (owner: owner, panelIDs: [])].panelIDs.append(panelId)
        }
        for group in groupedOwners.values {
            let owner = group.owner
            for panelId in group.panelIDs {
                if let provider = states[panelId]?.provider {
                    owner.setContextPressureProvider(panelId: panelId, provider: provider)
                }
                owner.setContextPressureMonitoringEnabled(
                    panelId: panelId,
                    enabled: true
                )
                evaluate(surfaceID: panelId, owner: owner)
            }
        }
    }

    /// Coalesces settings notifications onto one main-actor turn. UserDefaults
    /// broadcasts unrelated writes too, so unchanged context settings are
    /// filtered before walking the panel index.
    private func scheduleReevaluation(force: Bool) {
        pendingForcedReevaluation = pendingForcedReevaluation || force
        guard pendingReevaluationTask == nil else { return }
        pendingReevaluationTask = Task { @MainActor [weak self] in
            // Yield once so a batch of UserDefaults writes shares one pass.
            await Task.yield()
            guard let self, !Task.isCancelled else { return }
            self.pendingReevaluationTask = nil
            let shouldForce = self.pendingForcedReevaluation
            self.pendingForcedReevaluation = false
            let snapshot = SettingsSnapshot(settings: self.settings)
            guard shouldForce || snapshot != self.lastSettingsSnapshot else { return }
            self.lastSettingsSnapshot = snapshot
            self.reevaluateAll()
        }
    }

    nonisolated private static func deliverOnMainActor(
        _ action: @escaping @MainActor @Sendable () -> Void
    ) {
        Task { @MainActor in action() }
    }

}
