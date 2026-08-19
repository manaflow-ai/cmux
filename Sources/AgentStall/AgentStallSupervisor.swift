import CMUXAgentLaunch
import Foundation
import OSLog

/// Supervises managed Claude Code and Codex panes for alive-but-stalled turns.
///
/// Managed hooks own turn boundaries. PTY output is bounded evidence attached
/// to the matching capture generation; it can never trigger an action itself.
@MainActor
final class AgentStallSupervisor {
    static let logger = Logger(
        subsystem: "com.cmuxterm.app",
        category: "agent-stall-supervisor"
    )
    weak var app: AppDelegate?
    let classifier: AgentStallClassifier
    let policy: AgentStallSupervisorPolicy
    let retryActionResolver: AgentStallRetryActionResolver
    let settings: AgentSessionAutoRetrySettings
    let presentation: AgentStallPresentation
    var statesByPanelID: [UUID: AgentStallSupervisorPanelState] = [:]
    var internalInputPanelIDs: Set<UUID> = []

    private let outputDemand: AgentStallOutputDemand
    private var settingsObserver: NSObjectProtocol? = nil

    init(
        app: AppDelegate,
        notificationStore: TerminalNotificationStore,
        outputDemand: AgentStallOutputDemand,
        classifier: AgentStallClassifier = AgentStallClassifier(),
        policy: AgentStallSupervisorPolicy = .standard,
        retryActionResolver: AgentStallRetryActionResolver = AgentStallRetryActionResolver(),
        settings: AgentSessionAutoRetrySettings = AgentSessionAutoRetrySettings()
    ) {
        self.app = app
        self.classifier = classifier
        self.policy = policy
        self.retryActionResolver = retryActionResolver
        self.settings = settings
        self.outputDemand = outputDemand
        self.presentation = AgentStallPresentation(notificationStore: notificationStore)

        settingsObserver = settings.observeDidChange { [weak self] in
            guard let self, !self.settings.isEnabled else { return }
            self.cancelScheduledRetries(reason: "setting-disabled")
        }
    }

    deinit {
        if let settingsObserver { settings.removeDidChangeObserver(settingsObserver) }
        for state in statesByPanelID.values { state.retryTimer?.invalidate() }
        outputDemand.clearAllCaptures()
    }

    /// Records an already-ordered managed lifecycle event from Claude/Codex hooks.
    func lifecycleDidChange(
        owner: ControlSidebarPanelOwner,
        panelID: UUID,
        key: String,
        lifecycle: AgentHibernationLifecycleState,
        promptBoundary: Bool,
        normalCompletion: Bool = false,
        hookFailureEvidence: Bool = false,
        outputCapture: AgentStallOutputCapture? = nil
    ) {
        guard owner.containsAgentStallPanel(panelID),
              let binding = owner.agentStallResumeBinding(panelID),
              let provider = supportedProvider(kind: binding.kind, key: key) else {
            return
        }
        guard binding.hasCompleteManagedSessionIdentity else {
            cancel(panelID: panelID, reason: "unsupported-or-unbound-lifecycle")
            return
        }

        var state = statesByPanelID[panelID] ?? AgentStallSupervisorPanelState()
        if let previousOwner = state.ownerToken,
           previousOwner != owner.agentStallOwnerToken {
            cancel(panelID: panelID, reason: "owner-transferred")
            state = AgentStallSupervisorPanelState()
        }

        let sameSession = state.binding?.isSameManagedSession(as: binding) == true
        state.ownerToken = owner.agentStallOwnerToken
        state.binding = binding

        switch lifecycle {
        case .running:
            handleRunningLifecycle(
                owner: owner,
                panelID: panelID,
                provider: provider,
                binding: binding,
                state: state,
                sameSession: sameSession
            )

        case .idle, .needsInput:
            guard state.generation > 0,
                  state.phase == .running
                    || state.phase == .retrying
                    || state.phase == .retryWaiting
                    || (state.phase == .idle
                        && state.boundaryCommitment == .normalCompletion
                        && state.pendingBoundary != nil) else {
                Self.logger.debug(
                    "event=boundary-rejected provider=\(provider, privacy: .public) workspace=\(owner.id, privacy: .public) panel=\(panelID, privacy: .public) reason=no-running-generation"
                )
                return
            }
            // Lifecycle-only updates are presentation hints, not turn
            // boundaries. Preserve both the bounded capture and any committed
            // retry while the authoritative Stop event is still in flight.
            guard promptBoundary else {
                state.lifecycle = lifecycle
                statesByPanelID[panelID] = state
                Self.logger.debug(
                    "event=lifecycle-duplicate provider=\(provider, privacy: .public) workspace=\(owner.id, privacy: .public) panel=\(panelID, privacy: .public) generation=\(state.generation) state=\(lifecycle.rawValue, privacy: .public) reason=non-authoritative-update"
                )
                return
            }

            switch state.boundaryCommitment {
            case .actionCommitted:
                // Once an action has been selected, duplicate authoritative
                // hook events cannot replace or cancel it.
                state.lifecycle = lifecycle
                statesByPanelID[panelID] = state
                Self.logger.debug(
                    "event=boundary-duplicate provider=\(provider, privacy: .public) workspace=\(owner.id, privacy: .public) panel=\(panelID, privacy: .public) generation=\(state.generation) reason=action-committed"
                )
                return
            case .normalCompletion where !hookFailureEvidence:
                state.lifecycle = lifecycle
                statesByPanelID[panelID] = state
                Self.logger.debug(
                    "event=boundary-duplicate provider=\(provider, privacy: .public) workspace=\(owner.id, privacy: .public) panel=\(panelID, privacy: .public) generation=\(state.generation) reason=normal-completion-committed"
                )
                return
            case .normalCompletion:
                // Structured provider failure is the one fact allowed to
                // supersede an earlier generic completion hint.
                state.boundaryCommitment = .open
            case .open:
                break
            }

            let previousBoundary = state.pendingBoundary
            let hasStructuredEvidence = hookFailureEvidence
                || previousBoundary?.hasStructuredEvidence == true
            state.pendingBoundary = AgentStallSupervisorPanelState.PendingBoundary(
                generation: state.generation,
                normalCompletion: hasStructuredEvidence
                    ? false
                    : normalCompletion || previousBoundary?.normalCompletion == true,
                hasStructuredEvidence: hasStructuredEvidence,
                outputCapture: outputCapture ?? previousBoundary?.outputCapture
            )
            state.lifecycle = lifecycle
            statesByPanelID[panelID] = state
            let boundary = state.pendingBoundary
            evaluate(
                owner: owner,
                panelID: panelID,
                provider: provider,
                binding: binding,
                generation: state.generation,
                normalCompletion: boundary?.normalCompletion ?? normalCompletion,
                hookFailureEvidence: boundary?.hasStructuredEvidence ?? hookFailureEvidence,
                outputCapture: boundary?.outputCapture ?? outputCapture
            )

        case .unknown:
            Self.logger.debug(
                "event=lifecycle provider=\(provider, privacy: .public) workspace=\(owner.id, privacy: .public) panel=\(panelID, privacy: .public) generation=\(state.generation) state=unknown"
            )
            cancel(panelID: panelID, reason: "lifecycle-unknown")
        }
    }

    /// Refreshes process identity when the PID hook and lifecycle hook arrive
    /// on separate socket turns. Hook producers normally send PID first, but
    /// the supervisor must remain correct if the main-actor mutation bus
    /// observes the lifecycle boundary first. An unavailable identity is kept
    /// as unknown (and therefore cannot authorize an action); a replacement
    /// identity cancels the captured generation rather than risking a retry in
    /// a different process.
    func processDidChange(
        owner: ControlSidebarPanelOwner,
        panelID: UUID,
        key: String,
        pid: Int32
    ) {
        guard var state = statesByPanelID[panelID],
              state.ownerToken == owner.agentStallOwnerToken,
              state.lifecycle == .running || state.lifecycle == .idle || state.lifecycle == .needsInput,
              state.phase == .running || state.phase == .retrying || state.phase == .retryWaiting
                  || (state.phase == .idle && state.pendingBoundary != nil),
              let binding = owner.agentStallResumeBinding(panelID),
              let provider = supportedProvider(kind: binding.kind, key: key),
              state.binding?.isSameManagedSession(as: binding) == true else {
            return
        }

        let current = owner.agentStallProcessIdentity(
            provider: provider,
            checkpointID: binding.checkpointId ?? "",
            panelID: panelID
        )
        guard let current else {
            // Keep the missing identity explicit. The next boundary will be
            // rejected by the process-liveness gate until a matching PID is
            // published, rather than treating a bare PID as proof of life.
            state.processID = pid
            state.processIdentity = nil
            statesByPanelID[panelID] = state
            Self.logger.debug(
                "event=process-identity-unknown provider=\(provider, privacy: .public) workspace=\(owner.id, privacy: .public) panel=\(panelID, privacy: .public)"
            )
            return
        }

        guard current.pid == pid else {
            Self.logger.warning(
                "event=process-identity-rejected provider=\(provider, privacy: .public) workspace=\(owner.id, privacy: .public) panel=\(panelID, privacy: .public) reportedPID=\(pid) resolvedPID=\(current.pid) reason=key-mismatch"
            )
            cancel(panelID: panelID, reason: "process-key-mismatch")
            return
        }

        if let previousPID = state.processID,
           let previousIdentity = state.processIdentity,
           (previousPID != current.pid || previousIdentity != current.identity) {
            cancel(panelID: panelID, reason: "process-generation-replaced")
            return
        }
        state.processID = current.pid
        state.processIdentity = current.identity
        statesByPanelID[panelID] = state
        Self.logger.debug(
            "event=process-identity-refreshed provider=\(provider, privacy: .public) workspace=\(owner.id, privacy: .public) panel=\(panelID, privacy: .public) pid=\(current.pid)"
        )
        if let boundary = state.pendingBoundary,
           boundary.generation == state.generation,
           state.boundaryCommitment == .open,
           state.lifecycle == .idle || state.lifecycle == .needsInput {
            evaluate(
                owner: owner,
                panelID: panelID,
                provider: provider,
                binding: binding,
                generation: state.generation,
                normalCompletion: boundary.normalCompletion,
                hookFailureEvidence: boundary.hasStructuredEvidence,
                outputCapture: boundary.outputCapture
            )
        }
    }

    func evaluate(
        owner: ControlSidebarPanelOwner,
        panelID: UUID,
        provider: String,
        binding: SurfaceResumeBindingSnapshot,
        generation: UInt64,
        normalCompletion: Bool,
        hookFailureEvidence: Bool,
        outputCapture: AgentStallOutputCapture?
    ) {
        guard var state = statesByPanelID[panelID],
              state.generation == generation,
              state.ownerToken == owner.agentStallOwnerToken,
              state.lifecycle == .idle || state.lifecycle == .needsInput,
              state.boundaryCommitment == .open,
              let currentBinding = owner.agentStallResumeBinding(panelID),
              currentBinding.isSameManagedSession(as: binding) else {
            Self.logger.debug(
                "event=evaluation-rejected provider=\(provider, privacy: .public) workspace=\(owner.id, privacy: .public) panel=\(panelID, privacy: .public) generation=\(generation) reason=stale-state"
            )
            return
        }

        let classification: AgentStallClassification?
        if let outputCapture,
           outputCapture.descriptor.workspaceID == owner.id,
           outputCapture.descriptor.epoch == generation,
           !outputCapture.tail.isEmpty {
            classification = classifier.classify(
                provider: provider,
                output: String(decoding: outputCapture.tail, as: UTF8.self),
                hasStructuredEvidence: hookFailureEvidence
            )
        } else {
            classification = nil
        }
        let processLiveness = owner.agentStallProcessLiveness(
            provider: provider,
            checkpointID: binding.checkpointId ?? "",
            panelID: panelID,
            recordedPID: state.processID,
            recordedIdentity: state.processIdentity
        )
        guard state.processID != nil, state.processIdentity != nil else {
            // PID and lifecycle reports are independent socket mutations. Keep
            // the boundary pending so processDidChange can evaluate it after the
            // owner records a birth-time identity; no action is allowed yet.
            Self.logger.debug(
                "event=evaluation-deferred provider=\(provider, privacy: .public) workspace=\(owner.id, privacy: .public) panel=\(panelID, privacy: .public) generation=\(generation) reason=process-identity-pending"
            )
            return
        }
        let matchesCapturedProcess = if let processID = state.processID,
                                        let processIdentity = state.processIdentity {
            owner.agentStallMatchesProcessGeneration(
                provider: provider,
                checkpointID: binding.checkpointId ?? "",
                panelID: panelID,
                recordedPID: processID,
                recordedIdentity: processIdentity
            )
        } else {
            false
        }
        let input = AgentStallSupervisorInput(
            session: AgentStallSessionIdentity(
                provider: provider,
                checkpointID: binding.checkpointId ?? ""
            ),
            classification: classification,
            observedGeneration: generation,
            activeGeneration: state.generation,
            hasManagedLifecycle: true,
            hasManagedBinding: binding.hasCompleteManagedSessionIdentity,
            bindingMatches: currentBinding.isSameManagedSession(as: binding)
                && matchesCapturedProcess,
            promptBoundary: .managedPromptIdle,
            processLiveness: processLiveness,
            userInterrupted: false,
            normalCompletion: normalCompletion,
            autoRetryEnabled: settings.isEnabled,
            completedRetryAttempts: state.retryAttempts
        )
        let decision = policy.decision(for: input)

        if let classification {
            Self.logger.info(
                "event=classification provider=\(classification.provider, privacy: .public) pattern=\(classification.patternIdentifier, privacy: .public) cause=\(classification.cause.rawValue, privacy: .public) disposition=\(classification.disposition.rawValue, privacy: .public) workspace=\(owner.id, privacy: .public) panel=\(panelID, privacy: .public) generation=\(generation) normalCompletion=\(normalCompletion) hookFailureEvidence=\(hookFailureEvidence)"
            )
        } else {
            Self.logger.debug(
                "event=classification provider=\(provider, privacy: .public) result=unknown workspace=\(owner.id, privacy: .public) panel=\(panelID, privacy: .public) generation=\(generation) normalCompletion=\(normalCompletion) hookFailureEvidence=\(hookFailureEvidence)"
            )
        }

        switch decision {
        case let .notify(cause, suggestedActionID):
            state.boundaryCommitment = .actionCommitted
            state.pendingBoundary = nil
            state.phase = .humanRequired
            statesByPanelID[panelID] = state
            presentation.presentHumanRequired(
                owner: owner,
                panelID: panelID,
                provider: provider,
                cause: cause,
                suggestedActionID: suggestedActionID,
                generation: generation
            )
            Self.logger.warning(
                "event=human-required provider=\(provider, privacy: .public) cause=\(cause.rawValue, privacy: .public) workspace=\(owner.id, privacy: .public) panel=\(panelID, privacy: .public) generation=\(generation)"
            )

        case let .retry(attempt, maximumAttempts, delaySeconds, actionID):
            guard let retryInput = retryActionResolver.input(
                for: actionID,
                provider: provider
            ) else {
                state.boundaryCommitment = .actionCommitted
                state.pendingBoundary = nil
                state.phase = .idle
                statesByPanelID[panelID] = state
                Self.logger.error(
                    "event=action-suppressed provider=\(provider, privacy: .public) action=\(actionID, privacy: .public) workspace=\(owner.id, privacy: .public) panel=\(panelID, privacy: .public) generation=\(generation) reason=unsupported-retry-action"
                )
                return
            }
            state.boundaryCommitment = .actionCommitted
            state.pendingBoundary = nil
            statesByPanelID[panelID] = state
            scheduleRetry(
                owner: owner,
                panelID: panelID,
                binding: binding,
                provider: provider,
                generation: generation,
                attempt: attempt,
                maximumAttempts: maximumAttempts,
                delaySeconds: delaySeconds,
                actionID: actionID,
                input: retryInput
            )

        case let .ignore(rejection):
            Self.logger.debug(
                "event=action-suppressed provider=\(provider, privacy: .public) rejection=\(String(describing: rejection), privacy: .public) workspace=\(owner.id, privacy: .public) panel=\(panelID, privacy: .public) generation=\(generation)"
            )
            if rejection == .normalCompletion {
                // Retain the bounded capture so a later structured provider
                // failure can supersede this generic completion hint.
                state.boundaryCommitment = .normalCompletion
                state.phase = .idle
                statesByPanelID[panelID] = state
            } else if rejection == .exhausted {
                state.boundaryCommitment = .actionCommitted
                state.pendingBoundary = nil
                statesByPanelID[panelID] = state
                markExhausted(
                    owner: owner,
                    panelID: panelID,
                    generation: generation,
                    reason: "budget"
                )
            } else {
                state.boundaryCommitment = .actionCommitted
                state.pendingBoundary = nil
                state.phase = .idle
                statesByPanelID[panelID] = state
            }
        }
    }

    func cancel(panelID: UUID, reason: String, clearStatus: Bool = true) {
        // Explicit-input delivery reaches this method on every keystroke. The
        // overwhelmingly common unmanaged/no-recovery case must stay an O(1)
        // dictionary miss with no lock, workspace scan, or string formatting.
        guard let state = statesByPanelID.removeValue(forKey: panelID) else { return }
        state.retryTimer?.invalidate()
        // A generic completion may retain its tail briefly while waiting for
        // structured failure evidence. Any cancellation (including explicit
        // user input) must discard that tail so it cannot bleed into a later
        // turn that happens not to publish a fresh running hook.
        outputDemand.clearCapture(for: panelID)
        if clearStatus, state.phase.hasVisibleStatus {
            clearStatusEverywhere(panelID: panelID)
        }
        Self.logger.debug(
            "event=cancelled owner=\(state.ownerToken ?? "unknown", privacy: .public) panel=\(panelID, privacy: .public) generation=\(state.generation) reason=\(reason, privacy: .public)"
        )
    }

    private func cancelScheduledRetries(reason: String) {
        let panelIDs = statesByPanelID.compactMap { panelID, state in
            state.phase == .retryWaiting || state.phase == .retrying
                ? panelID
                : nil
        }
        for panelID in panelIDs {
            cancel(panelID: panelID, reason: reason)
        }
    }
}
