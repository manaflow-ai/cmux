import CMUXAgentLaunch
import CmuxSidebar
import CmuxWorkspaces
import Foundation

@MainActor
extension AgentContextManagementCoordinator {
    /// Bounds how long a provider hook may wait for its matching PTY marker.
    static let providerEvidenceMaximumAge: TimeInterval = 60
    private static let invalidEvidenceSurfaceID = UUID(
        uuidString: "00000000-0000-0000-0000-000000000000"
    )!

    private static func feedSource(for provider: AgentContextProvider) -> String {
        switch provider {
        case .claudeCode: return "claude"
        case .codex: return "codex"
        }
    }

    private static func uuid(from rawValue: String?) -> UUID? {
        guard let rawValue else { return nil }
        return UUID(uuidString: rawValue.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func eventSessionMatchesBinding(
        _ rawEventSessionID: String,
        source: String,
        bindingKind: String?,
        checkpointID: String
    ) -> Bool {
        let trimmed = rawEventSessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let prefix = "\(source.lowercased())-"
        let unprefixed = trimmed.lowercased().hasPrefix(prefix)
            ? String(trimmed.dropFirst(prefix.count))
            : trimmed
        let candidates = [trimmed, unprefixed]
        return candidates.contains { candidate in
            checkpointID.caseInsensitiveCompare(candidate) == .orderedSame
                || ManagedAgentSessionIdentity.sessionIDsMatch(
                    kind: bindingKind ?? source,
                    lhs: checkpointID,
                    rhs: candidate
                )
        }
    }

    /// Returns whether a structured provider event is recent enough to apply.
    ///
    /// - Parameters:
    ///   - receivedAt: The event's receipt timestamp.
    ///   - now: The acceptance timestamp used for the bounded comparison.
    static func providerEvidenceIsFresh(
        _ receivedAt: Date?,
        now: Date = Date()
    ) -> Bool {
        guard let receivedAt else { return false }
        let age = now.timeIntervalSince(receivedAt)
        return age >= 0 && age <= providerEvidenceMaximumAge
    }

    /// Accepts one provider-originated compaction hook as independent evidence
    /// for the currently visible pressure episode. Raw PTY markers continue to
    /// drive diagnostics and sidebar status, but never authorize a write on
    /// their own.
    func confirmProviderEvidence(from event: WorkstreamEvent) {
        guard event.hookEventName == .preCompact else { return }
        guard let provider = AgentContextProvider(managedAgentKind: event.source),
              Self.feedSource(for: provider) == event.source.lowercased() else {
            structuredLog(
                "provider-evidence.ignored",
                workspaceID: nil,
                surfaceID: Self.invalidEvidenceSurfaceID,
                detail: "reason=source-mismatch source=\(event.source)"
            )
            return
        }
        let claimedWorkspaceID = Self.uuid(from: event.workspaceId)
        let claimedSurfaceID = Self.uuid(from: event.surfaceId)
        guard let workspaceID = Self.uuid(from: event.workspaceId),
              let surfaceID = Self.uuid(from: event.surfaceId),
              let owner = owner(for: surfaceID, preferredWorkspaceID: workspaceID),
              owner.workspaceID == workspaceID,
              owner.contains(panelId: surfaceID),
              let binding = owner.binding(panelId: surfaceID),
              AgentContextProvider(managedAgentKind: binding.kind) == provider,
              let checkpointID = binding.checkpointId,
              Self.eventSessionMatchesBinding(
                  event.sessionId,
                  source: event.source,
                  bindingKind: binding.kind,
                  checkpointID: checkpointID
              ) else {
            structuredLog(
                "provider-evidence.ignored",
                workspaceID: claimedWorkspaceID,
                surfaceID: claimedSurfaceID ?? Self.invalidEvidenceSurfaceID,
                detail: "reason=target-or-session-mismatch source=\(event.source)"
            )
            return
        }

        owner.setContextPressureMonitoringEnabled(panelId: surfaceID, enabled: true)
        owner.setContextPressureProvider(panelId: surfaceID, provider: provider)
        var state = states[surfaceID]
            ?? makePanelState(
                panelId: surfaceID,
                provider: provider,
                binding: binding,
                owner: owner,
                detectorGeneration: owner.contextPressureDetectorGeneration(panelId: surfaceID),
                userInputObserved: userInputObservedBeforePressure.contains(surfaceID)
            )
        guard state.provider == provider, sameSession(state.binding, binding) else {
            structuredLog(
                "provider-evidence.ignored",
                workspaceID: workspaceID,
                surfaceID: surfaceID,
                detail: "reason=state-session-mismatch"
            )
            return
        }
        let acceptedAt = Date()
        guard Self.providerEvidenceIsFresh(event.receivedAt, now: acceptedAt) else {
            structuredLog(
                "provider-evidence.ignored",
                workspaceID: workspaceID,
                surfaceID: surfaceID,
                detail: "reason=stale-event"
            )
            return
        }
        // The hook is independent evidence and may arrive before the PTY
        // marker or its lifecycle callback. It is still bound to this exact
        // session and expires before it can span an unrelated later turn.
        state.providerEvidenceConfirmed = true
        state.providerEvidenceReceivedAt = acceptedAt
        states[surfaceID] = state
        structuredLog(
            "provider-evidence.confirmed",
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            detail: "source=\(event.source) hook=\(event.hookEventName.rawValue)"
        )
        if state.pressure.isUnderPressure {
            evaluate(surfaceID: surfaceID, owner: owner)
        }
    }

    func evaluate(surfaceID: UUID, owner: PanelOwner) {
        guard var state = states[surfaceID] else { return }
        guard let binding = owner.binding(panelId: surfaceID),
              sameSession(state.binding, binding) else {
            resetForUnboundSession(panelId: surfaceID)
            return
        }
        let liveTerminal = owner.terminal(panelId: surfaceID)
        let preservationPathAvailable = !settings.preservesState
            || state.preservationCompleted
            || owner.contextHandoffFileURL(panelId: surfaceID) != nil
        let input = AgentContextInjectionInput(
            enabled: settings.isEnabled,
            pressureDetected: state.pressure.isUnderPressure,
            pressureConfirmed: state.pressureConfirmation.isConfirmed,
            providerEvidenceConfirmed: state.providerEvidenceConfirmed,
            managedSessionBound: owner.binding(panelId: surfaceID)?.isAgentHookBinding == true,
            foregroundAgentConfirmed: owner.hasVerifiedForegroundAgentProcess(
                panelId: surfaceID,
                provider: state.provider
            ),
            provider: state.provider,
            lifecycle: state.lifecycle,
            shellActivity: state.shellActivity,
            dialogOpen: state.dialogOpen || owner.hasDialogOpen(panelId: surfaceID),
            userInputObserved: state.userInputObserved,
            injectionInFlight: state.injectionInFlight,
            action: settings.action,
            preserveState: settings.preservesState,
            preservationCompleted: state.preservationCompleted,
            preservationAwaitingAcknowledgement: state.preservationAwaitingAcknowledgement,
            manualRecoveryRequired: state.manualRecoveryRequired,
            surfaceAvailable: liveTerminal?.surface.hasLiveSurface == true,
            preservationAvailable: preservationPathAvailable
        )
        let decision = policy.decide(input)
        structuredLog(
            "gating",
            workspaceID: owner.workspaceID,
            surfaceID: surfaceID,
            detail: "decision=\(String(describing: decision))"
        )
        guard case .inject(let step) = decision else {
            if case .unsafe(let reason) = decision, settings.action == .clear {
                let shouldNotify = !state.unsafeClearNotificationSent
                // A lifecycle/provider confirmation can legitimately arrive
                // after the first marker. Do not turn that transient evidence
                // gap into a permanent manual-intervention latch.
                if reason != AgentContextInjectionBlockReason.pressureUnconfirmed {
                    state.manualRecoveryRequired = true
                }
                if reason == .preservationUnavailable {
                    state.preservationAwaitingAcknowledgement = true
                    state.preservationCompleted = false
                    state.preservationHandoffPath = nil
                    state.preservationRequestedAt = nil
                    state.preservationBaseline = nil
                    state.preservationPreparationInFlight = false
                    state.preservationVerificationInFlight = false
                }
                state.unsafeClearNotificationSent = true
                states[surfaceID] = state
                if shouldNotify {
                    notifyUnsafeClear(owner: owner, surfaceID: surfaceID, reason: reason)
                }
            }
            return
        }
        guard let terminal = liveTerminal else {
            let shouldNotify = settings.action == .clear && !state.unsafeClearNotificationSent
            if settings.action == .clear {
                state.manualRecoveryRequired = true
                state.unsafeClearNotificationSent = true
            }
            states[surfaceID] = state
            if shouldNotify {
                notifyUnsafeClear(
                    owner: owner,
                    surfaceID: surfaceID,
                    reason: .surfaceUnavailable
                )
            }
            structuredLog(
                "injection.rejected",
                workspaceID: owner.workspaceID,
                surfaceID: surfaceID,
                detail: "step=\(step.rawValue) reason=surface-unavailable"
            )
            return
        }

        if step == .preserveState {
            // A new pressure episode gets a fresh opportunity to preserve
            // state, even if an earlier unsafe-clear notification was sent.
            state.unsafeClearNotificationSent = false
            guard let handoffPath = owner.contextHandoffFileURL(panelId: surfaceID) else {
                state.manualRecoveryRequired = true
                state.unsafeClearNotificationSent = true
                state.preservationAwaitingAcknowledgement = true
                state.preservationHandoffPath = nil
                state.preservationRequestedAt = nil
                state.preservationBaseline = nil
                state.preservationPreparationInFlight = false
                state.preservationVerificationInFlight = false
                states[surfaceID] = state
                notifyUnsafeClear(
                    owner: owner,
                    surfaceID: surfaceID,
                    reason: .preservationUnavailable
                )
                structuredLog(
                    "injection.rejected",
                    workspaceID: owner.workspaceID,
                    surfaceID: surfaceID,
                    detail: "step=\(step.rawValue) reason=handoff-path-unavailable"
                )
                return
            }

            // Capture the existing handoff identity off the main actor before
            // asking the provider to write. This is required on filesystems
            // whose mtime resolution is coarser than the request clock.
            if state.preservationHandoffPath != handoffPath {
                state.preservationHandoffPath = handoffPath
                state.preservationBaseline = nil
                state.preservationPreparationInFlight = false
                state.preservationRequestedAt = nil
            }
            guard !state.preservationPreparationInFlight else {
                states[surfaceID] = state
                return
            }
            guard let baseline = state.preservationBaseline else {
                state.preservationHandoffPath = handoffPath
                state.preservationPreparationInFlight = true
                state.injectionInFlight = true
                state.preservationCompleted = false
                state.preservationVerificationInFlight = false
                states[surfaceID] = state
                beginPreservationPreparation(
                    panelId: surfaceID,
                    path: handoffPath
                )
                return
            }
            if case .unavailable = baseline {
                let shouldNotify = !state.unsafeClearNotificationSent
                state.injectionInFlight = false
                state.preservationPreparationInFlight = false
                // No preservation command was sent, so there is no lifecycle
                // boundary to await. The manual-recovery latch below prevents
                // repeated asynchronous baseline probes/notifications.
                state.preservationAwaitingAcknowledgement = false
                state.preservationCompleted = false
                state.preservationRequestedAt = nil
                state.manualRecoveryRequired = true
                state.unsafeClearNotificationSent = true
                states[surfaceID] = state
                if shouldNotify {
                    notifyUnsafeClear(
                        owner: owner,
                        surfaceID: surfaceID,
                        reason: .preservationUnavailable
                    )
                }
                structuredLog(
                    "injection.rejected",
                    workspaceID: owner.workspaceID,
                    surfaceID: surfaceID,
                    detail: "step=\(step.rawValue) reason=handoff-baseline-unavailable"
                )
                return
            }
            state.preservationHandoffPath = handoffPath
            state.preservationRequestedAt = Date()
            state.preservationCompleted = false
            state.preservationVerificationInFlight = false
        }

        state.injectionInFlight = true
        // Clear detector occurrence history at the tee boundary before the
        // provider receives recovery input. The tee owns parser mutation; this
        // call only publishes an event-driven reset request.
        state.detectorGeneration = terminal.surface.resetContextPressureDetectors()
        states[surfaceID] = state
        structuredLog(
            "detector-reset-requested",
            workspaceID: owner.workspaceID,
            surfaceID: surfaceID,
            detail: "step=\(step.rawValue) generation=\(state.detectorGeneration)"
        )
        let text: String
        switch step {
        case .preserveState:
            text = String(localized: "agentContext.preserveInstruction", defaultValue: "Before starting a fresh context, write a brief handoff note to .cmux-context-handoff.md in the current working directory, including the current task state and next steps. The next context should read it before continuing.")
        case .compact:
            text = state.provider.recoveryCommand(for: .compact)
        case .clear:
            text = state.provider.recoveryCommand(for: .clear)
        }
        let accepted = terminal.surface.sendContextManagementInput(text + "\n")
        guard accepted else {
            state.injectionInFlight = false
            if step == .preserveState {
                state.preservationHandoffPath = nil
                state.preservationRequestedAt = nil
                state.preservationVerificationInFlight = false
            }
            var shouldNotify = false
            if settings.action == .clear {
                shouldNotify = !state.unsafeClearNotificationSent
                state.manualRecoveryRequired = true
                state.unsafeClearNotificationSent = true
            }
            states[surfaceID] = state
            if shouldNotify {
                notifyUnsafeClear(
                    owner: owner,
                    surfaceID: surfaceID,
                    reason: .surfaceUnavailable
                )
            }
            structuredLog(
                "injection.rejected",
                workspaceID: owner.workspaceID,
                surfaceID: surfaceID,
                detail: "step=\(step.rawValue) reason=input-rejected"
            )
            return
        }
        notifyInjection(owner: owner, surfaceID: surfaceID, step: step, command: text)
        if step == .preserveState {
            state.preservationAwaitingAcknowledgement = true
            state.preservationObservedRunning = false
            state.injectionInFlight = false
            state.preservationVerificationInFlight = false
            states[surfaceID] = state
            return
        }
        state.injectionInFlight = false
        state.preservationCompleted = false
        state.recoveryAwaitingLifecycleBoundary = true
        state.recoveryObservedRunning = false
        state.unsafeClearNotificationSent = false
        state.manualRecoveryRequired = false
        state.providerEvidenceConfirmed = false
        state.providerEvidenceReceivedAt = nil
        state.preservationHandoffPath = nil
        state.preservationRequestedAt = nil
        state.preservationBaseline = nil
        state.preservationPreparationInFlight = false
        state.preservationVerificationInFlight = false
        state.pressure = AgentContextPressureSnapshot()
        state.pressureConfirmation.reset()
        userInputObservedBeforePressure.remove(surfaceID)
        state.userInputObserved = false
        states[surfaceID] = state
        owner.clearPressureStatus(key: Self.statusKey(for: surfaceID), panelId: surfaceID)
    }

    /// Captures pre-request handoff evidence off the main actor.
    func beginPreservationPreparation(
        panelId: UUID,
        path: URL
    ) {
        let verifier = handoffVerifier
        preservationPreparationTasks[panelId]?.cancel()
        preservationPreparationTasks[panelId] = Task { @MainActor [weak self, verifier] in
            let baseline = await verifier.capture(path: path)
            guard !Task.isCancelled else { return }
            self?.finishPreservationPreparation(
                panelId: panelId,
                path: path,
                baseline: baseline
            )
        }
    }

    private func finishPreservationPreparation(
        panelId: UUID,
        path: URL,
        baseline: AgentContextHandoffVerificationBaseline
    ) {
        preservationPreparationTasks.removeValue(forKey: panelId)
        guard var state = states[panelId],
              state.preservationPreparationInFlight,
              state.preservationHandoffPath == path else {
            return
        }
        state.preservationPreparationInFlight = false
        state.injectionInFlight = false
        state.preservationBaseline = baseline
        states[panelId] = state
        guard let owner = owner(for: panelId, preferredWorkspaceID: nil),
              let binding = owner.binding(panelId: panelId),
              sameSession(state.binding, binding) else {
            return
        }
        evaluate(surfaceID: panelId, owner: owner)
    }

    /// Verifies a preservation request after the provider's real idle boundary.
    ///
    /// The lifecycle transition is necessary but not sufficient: the provider
    /// must also have created a changed, non-empty handoff file after cmux asked
    /// for it. The pre-request fingerprint handles coarse mtimes. The actor
    /// performs filesystem work off the main actor and
    /// returns one value back through this coordinator's event-driven lane.
    func beginPreservationVerification(
        panelId: UUID,
        path: URL,
        requestedAt: Date,
        baseline: AgentContextHandoffVerificationBaseline
    ) {
        let verifier = handoffVerifier
        preservationVerificationTasks[panelId]?.cancel()
        preservationVerificationRequestedAtByPanel[panelId] = requestedAt
        preservationVerificationTasks[panelId] = Task { @MainActor [weak self, verifier] in
            let result = await verifier.verify(
                path: path,
                requestedAt: requestedAt,
                baseline: baseline
            )
            guard !Task.isCancelled else { return }
            self?.finishPreservationVerification(
                panelId: panelId,
                path: path,
                requestedAt: requestedAt,
                result: result
            )
        }
    }

    private func finishPreservationVerification(
        panelId: UUID,
        path: URL,
        requestedAt: Date,
        result: AgentContextHandoffVerifier.Result
    ) {
        guard preservationVerificationRequestedAtByPanel[panelId] == requestedAt else {
            return
        }
        preservationVerificationTasks.removeValue(forKey: panelId)
        preservationVerificationRequestedAtByPanel.removeValue(forKey: panelId)
        guard var state = states[panelId],
              state.preservationAwaitingAcknowledgement,
              state.preservationHandoffPath == path,
              state.preservationRequestedAt == requestedAt else {
            return
        }
        state.preservationVerificationInFlight = false
        state.preservationPreparationInFlight = false
        state.preservationBaseline = nil
        let expectedBinding = state.binding
        let currentOwner = owner(for: panelId, preferredWorkspaceID: nil).flatMap { owner in
            owner.binding(panelId: panelId).flatMap { binding in
                sameSession(expectedBinding, binding) ? owner : nil
            }
        }
        switch result {
        case .written:
            state.preservationAwaitingAcknowledgement = false
            state.preservationObservedRunning = false
            state.preservationCompleted = true
            states[panelId] = state
            if let currentOwner {
                structuredLog(
                    "preservation.acknowledged",
                    workspaceID: currentOwner.workspaceID,
                    surfaceID: panelId,
                    detail: "handoff-file=written"
                )
                evaluate(surfaceID: panelId, owner: currentOwner)
            }
        case .missing, .notRegularFile, .empty, .stale, .unreadable:
            // Keep the preservation phase pending and fail closed. The user
            // notification explains that cmux will not type `/clear` without
            // durable evidence; a later explicit user input starts a fresh
            // pressure episode and clears this gate.
            state.unsafeClearNotificationSent = currentOwner.map { _ in true } ?? false
            if currentOwner != nil {
                state.manualRecoveryRequired = true
            }
            if case .none = currentOwner {
                // A transfer may temporarily remove every owner. Allow the
                // destination binding callback to request preservation again.
                state.preservationAwaitingAcknowledgement = false
            }
            states[panelId] = state
            if let currentOwner {
                structuredLog(
                    "preservation.rejected",
                    workspaceID: currentOwner.workspaceID,
                    surfaceID: panelId,
                    detail: "handoff-file=\(result.rawValue)"
                )
                notifyUnsafeClear(
                    owner: currentOwner,
                    surfaceID: panelId,
                    reason: .preservationUnavailable
                )
            }
        }
    }

    /// Cancels a pending handoff verification without touching panel state.
    func cancelPreservationVerification(panelId: UUID) {
        preservationPreparationTasks.removeValue(forKey: panelId)?.cancel()
        preservationVerificationTasks.removeValue(forKey: panelId)?.cancel()
        preservationVerificationRequestedAtByPanel.removeValue(forKey: panelId)
    }

    private func notifyInjection(
        owner: PanelOwner,
        surfaceID: UUID,
        step: AgentContextInjectionStep,
        command: String
    ) {
        if case .workspace(let workspace) = owner {
            workspace.sidebarMetadata.appendLogEntry(
                message: String(localized: "sidebar.agentContext.injectedLog", defaultValue: "Context recovery input sent to the managed agent."),
                level: .success,
                source: "agent-context"
            )
        }
        let subtitle: String
        switch step {
        case .preserveState:
            subtitle = String(localized: "agentContext.notification.preserveSubtitle", defaultValue: "handoff note")
        case .compact, .clear:
            subtitle = command
        }
        AppDelegate.shared?.notificationStore?.addNotification(
            tabId: owner.workspaceID,
            surfaceId: surfaceID,
            title: String(localized: "agentContext.notification.title", defaultValue: "Context recovery sent"),
            subtitle: subtitle,
            body: String(localized: "agentContext.notification.body", defaultValue: "cmux sent context-recovery input after the agent reported context pressure."),
            cooldownKey: "agent-context-injection-\(surfaceID.uuidString)-\(step.rawValue)",
            cooldownInterval: 30
        )
        structuredLog("injection", workspaceID: owner.workspaceID, surfaceID: surfaceID, detail: "step=\(step.rawValue)")
    }

    func notifyUnsafeClear(owner: PanelOwner, surfaceID: UUID, reason: AgentContextInjectionBlockReason) {
        AppDelegate.shared?.notificationStore?.addNotification(
            tabId: owner.workspaceID,
            surfaceId: surfaceID,
            title: String(localized: "agentContext.notification.unsafeTitle", defaultValue: "Context clear needs your input"),
            subtitle: "",
            body: String(localized: "agentContext.notification.unsafeBody", defaultValue: "Context pressure was detected, but cmux could not prove a safe idle agent prompt. Return to the agent prompt and choose the provider's recovery command manually."),
            cooldownKey: "agent-context-unsafe-clear-\(surfaceID.uuidString)",
            cooldownInterval: 60
        )
        structuredLog(
            "unsafe-clear",
            workspaceID: owner.workspaceID,
            surfaceID: surfaceID,
            detail: "reason=\(reason.rawValue)"
        )
    }
}
