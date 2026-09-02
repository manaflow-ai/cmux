public import Foundation
public import GhosttyKit
public import CmuxTerminalCore
internal import Carbon.HIToolbox
#if DEBUG
internal import CMUXDebugLog
#endif

// MARK: - Socket/API input: send paths, pending queues, parsing

private enum PendingSocketInputDeliveryResult {
    case delivered
    case deferred
    case failed
}

extension TerminalSurface {
    /// The single agent-process identity that owns prompt-input tracking.
    @MainActor
    public var currentPromptInputAgentScope: String? {
        promptInputLedger.currentAgentScope
    }

    /// Whether this surface has an app-owned prompt awaiting hook matching.
    @MainActor
    public var hasPendingProgrammaticPromptSubmission: Bool {
        promptInputLedger.hasPendingProgrammaticSubmission
            || (pendingSocketInputQueue + deferredPromptSubmissionRetries)
                .contains { input in
                    guard case .promptSubmission(
                        _,
                        _,
                        _,
                        let hookRecordingSource,
                        _,
                        _,
                        _
                    ) = input else {
                        return false
                    }
                    return hookRecordingSource != nil
                }
    }

    @MainActor
    private var hasQueuedHumanPromptSubmission: Bool {
        (pendingSocketInputQueue + deferredPromptSubmissionRetries).contains {
            if case .humanPromptSubmission = $0 { return true }
            return false
        }
    }

    /// Returns the transport-owned name for a physical manual-I/O key, if any.
    @MainActor
    public func manualInputKeyName(for event: ghostty_input_key_s) -> String? {
        guard ioMode.usesManualIO, manualInputHandler != nil else { return nil }
        return manualInputKeyNameResolver?(event)
    }

    /// Queues a name from ``manualInputKeyName(for:)`` behind earlier Ghostty input.
    @MainActor
    public func enqueueManualInputNamedKey(_ name: String) -> Bool {
        guard ioMode.usesManualIO, manualInputHandler != nil, let surface else { return false }
        let frame = TerminalManualInput.namedKey(name).manualIOData
        return remoteOutputLane.enqueueTextInput(frame, to: surface)
    }

    /// Notifies the pane host that user-initiated terminal input is about to be sent.
    @MainActor
    @discardableResult
    public func didReceiveExplicitInput() -> Bool {
        var cancelledDeferredAdmission = false
        if cancelsStartupRestoreAdmissionOnExplicitInput,
           startupRestoreAdmissionPhase == .awaitingAdmission {
            cancelledDeferredAdmission = cancelStartupRestoreAdmissionForExplicitInput()
        }
        paneHost.terminalSurfaceDidReceiveExplicitInput()
        return cancelledDeferredAdmission
    }

    /// Routes programmatic input through the view-owned clipboard sequencer.
    @MainActor
    func deferInputDuringRuntimeClipboardRead(
        estimatedBytes: Int,
        isHumanInput: Bool = true,
        replay: @escaping () -> Void,
        onDiscard: @escaping () -> Void = {}
    ) -> Bool {
        surfaceView.deferRuntimeInputDuringClipboardRead(
            estimatedBytes: estimatedBytes,
            isHumanInput: isHumanInput,
            replay: replay,
            onDiscard: onDiscard
        )
    }

    /// Notifies the current panel owner after explicit terminal input is accepted.
    @MainActor
    public func didAcceptExplicitInput() {
        onExplicitInput?()
    }

    /// Records unowned input that may belong to a human's agent composer.
    ///
    /// Generic socket/mobile input records through this same ledger below.
    /// Attributed compound submissions deliberately use
    /// ``sendPromptSubmission``
    /// instead, so their hooks cannot consume an unowned human boundary.
    ///
    /// - Parameter mutation: The conservatively modeled composer mutation.
    @MainActor
    public func recordHumanPromptInput(
        _ mutation: HumanPromptInputMutation
    ) {
        promptInputLedger.recordHumanInput(mutation)
    }

    /// Classifies and records a forwarded physical or synthetic key without
    /// inspecting rendered terminal state.
    @MainActor
    public func recordHumanPromptKey(
        keycode: UInt32,
        mods: ghostty_input_mods_e
    ) {
        promptInputLedger.recordHumanInput(
            promptInputMutation(keycode: keycode, mods: mods)
        )
    }

    /// Records text that an external transport already accepted as generic
    /// terminal input.
    ///
    /// Remote transports bypass ``sendInputResult(_:)`` but still share this
    /// surface's agent-composer ownership. Return is a recoverable submission
    /// boundary only for agents whose cached submit chord is plain Return; a
    /// configured multiline agent treats it as unknown input.
    @MainActor
    public func recordAcceptedUnownedPromptInput(_ text: String) {
        guard !text.isEmpty else { return }
        let hasReturn = text.unicodeScalars.contains { scalar in
            scalar.value == 0x0A || scalar.value == 0x0D
        }
        guard hasReturn else {
            promptInputLedger.recordHumanInput(.unknown)
            return
        }

        var hasUnknownInput = false
        var previousWasCR = false
        let returnMutation: HumanPromptInputMutation =
            controlReturnIsPromptSubmissionBoundary
                ? .unknown
                : .submissionBoundary
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x0D:
                if hasUnknownInput {
                    promptInputLedger.recordHumanInput(.unknown)
                    hasUnknownInput = false
                }
                promptInputLedger.recordHumanInput(returnMutation)
                previousWasCR = true
            case 0x0A:
                if !previousWasCR {
                    if hasUnknownInput {
                        promptInputLedger.recordHumanInput(.unknown)
                        hasUnknownInput = false
                    }
                    promptInputLedger.recordHumanInput(returnMutation)
                }
                previousWasCR = false
            default:
                hasUnknownInput = true
                previousWasCR = false
            }
        }
        if hasUnknownInput {
            promptInputLedger.recordHumanInput(.unknown)
        }
    }

    /// Records a named key that an external transport already accepted.
    @MainActor
    public func recordAcceptedUnownedPromptKey(_ keyName: String) {
        let mutation = pendingKeyEvent(for: keyName).map {
            promptInputMutation(for: $0)
        } ?? .unknown
        promptInputLedger.recordHumanInput(mutation)
    }

    /// Aligns composer ownership with the currently bound agent process.
    /// Claude's plain Return is treated as an interior newline during its
    /// initial binding, so provisional Return boundaries remain fail-closed.
    @MainActor
    public func synchronizePromptInputAgentScope(
        _ scope: String?,
        controlReturnIsPromptSubmissionBoundary:
            Bool? = nil
    ) {
        let previousScope = promptInputLedger.currentAgentScope
        if let controlReturnIsPromptSubmissionBoundary {
            self.controlReturnIsPromptSubmissionBoundary =
                controlReturnIsPromptSubmissionBoundary
        }
        promptInputLedger.synchronizeAgentScope(
            scope,
            provisionalSubmissionBoundariesAreReliable:
                !self.controlReturnIsPromptSubmissionBoundary
        )
        if previousScope != scope {
            // A prompt retained across a process replacement can only replay
            // once its original scope is bound again. Reconcile that queue at
            // the same ownership transition instead of waiting for a new
            // runtime-surface creation event.
            flushPendingSocketInputIfNeeded()
        }
    }

    /// Matches an agent `UserPromptSubmit` hook to a known input boundary.
    @MainActor
    @discardableResult
    public func confirmPromptSubmission(message: String?)
        -> PromptSubmissionConfirmationOrigin
    {
        promptInputLedger.confirmSubmission(message: message)
    }

    /// Whether human terminal input may still be present in the current agent composer.
    @MainActor
    public var hasUnconfirmedHumanPromptInput: Bool {
        promptInputLedger.hasUnconfirmedHumanInput
    }

    /// Closes Find as an explicit user action, cancelling any deferred viewport restoration first.
    @MainActor
    public func closeSearchFromExplicitInput() {
        didReceiveExplicitInput()
        searchState = nil
        didAcceptExplicitInput()
    }

    /// Whether closing this surface should ask for confirmation.
    public func needsConfirmClose() -> Bool {
#if DEBUG
        if let needsConfirmCloseOverrideForTesting {
            return needsConfirmCloseOverrideForTesting
        }
#endif
        guard let surface, hasCloseConfirmationProcessRisk(surface) else { return false }
        return ghostty_surface_needs_confirm_quit(surface)
    }

    /// Records a completed runtime clipboard read and notifies observers.
    public func noteClipboardReadCompleted() {
        clipboardReadGeneration += 1
        NotificationCenter.default.post(
            name: .terminalSurfaceDidCompleteClipboardRead,
            object: self
        )
    }

    /// Sends paste-style text to the surface, queueing on a cold surface.
    ///
    /// - Returns: Whether the text was delivered or queued.
    @MainActor
    @discardableResult
    public func sendText(_ text: String) -> Bool {
        guard let data = text.data(using: .utf8), !data.isEmpty else { return true }
        didReceiveExplicitInput()
        let accepted = sendTextAfterExplicitInput(data)
        if accepted {
            hibernationRecorder.recordTerminalInput(
                workspaceId: tabId,
                panelId: id
            )
        }
        return accepted
    }

    @MainActor
    private func sendTextAfterExplicitInput(_ data: Data) -> Bool {
        if deferInputDuringRuntimeClipboardRead(
            estimatedBytes: data.count,
            replay: { [weak self] in
                _ = self?.sendTextAfterExplicitInput(data)
            }
        ) {
            return true
        }
        guard surface != nil else {
            guard allowsRuntimeSurfaceCreation() else { return false }
            let queued = enqueuePendingSocketInput(.pasteText(data))
            if queued {
                promptInputLedger.recordHumanInput(.unknown)
                requestInputDemandSurfaceStartIfNeeded()
                didAcceptExplicitInput()
            }
            return queued
        }
        guard let liveSurface = liveSurfaceForSocketWrite(reason: "socket.sendText") else {
            return false
        }
        guard !ghostty_surface_process_exited(liveSurface) else { return false }
        writeTextData(data, to: liveSurface)
        promptInputLedger.recordHumanInput(.unknown)
        didAcceptExplicitInput()
        return true
    }

    /// Sends raw key text as a single key event.
    ///
    /// - Returns: Whether the runtime handled the key.
    @MainActor
    @discardableResult
    public func sendKeyText(_ text: String) -> Bool {
        guard !text.isEmpty else { return true }
        didReceiveExplicitInput()
        return sendKeyTextAfterExplicitInput(text)
    }

    @MainActor
    private func sendKeyTextAfterExplicitInput(_ text: String) -> Bool {
        if deferInputDuringRuntimeClipboardRead(
            estimatedBytes: text.utf8.count,
            replay: { [weak self] in
                _ = self?.sendKeyTextAfterExplicitInput(text)
            }
        ) {
            return true
        }
        guard surface != nil else {
            guard allowsRuntimeSurfaceCreation() else { return false }
            let queued = enqueuePendingSocketInput(.keyText(text))
            if queued {
                requestInputDemandSurfaceStartIfNeeded()
                didAcceptExplicitInput()
            }
            return queued
        }
        guard let liveSurface = liveSurfaceForSocketWrite(reason: "socket.sendKeyText") else {
            return false
        }
        guard !ghostty_surface_process_exited(liveSurface) else { return false }

        return sendKeyText(text, to: liveSurface)
    }

    @MainActor
    private func sendKeyText(
        _ text: String,
        to liveSurface: ghostty_surface_t
    ) -> Bool {

        var keyEvent = ghostty_input_key_s()
        keyEvent.action = GHOSTTY_ACTION_PRESS
        keyEvent.keycode = 0
        keyEvent.mods = GHOSTTY_MODS_NONE
        keyEvent.consumed_mods = GHOSTTY_MODS_NONE
        keyEvent.unshifted_codepoint = 0
        keyEvent.composing = false
        let handled = text.withCString { ptr in
            keyEvent.text = ptr
            return withRuntimeClipboardPasteIntent {
                ghostty_surface_key(liveSurface, keyEvent)
            }
        }
        if handled {
            promptInputLedger.recordHumanInput(.unknown)
            didAcceptExplicitInput()
        }
        return handled
    }

    /// Sends a named key (e.g. `"ctrl-c"`, `"enter"`), queueing on a cold
    /// surface.
    @MainActor
    @discardableResult
    public func sendNamedKey(_ keyName: String) -> NamedKeySendResult {
        sendNamedKeyWithOwnership(keyName, recordPromptInput: true)
    }

    /// Sends a named key owned by an app control without recording it as human
    /// composer input.
    ///
    /// Mobile chat interrupts use this path for Esc and Ctrl-C. The key still
    /// follows the normal runtime and clipboard sequencing rules, but it does
    /// not create an unconfirmed human composer mutation.
    @MainActor
    @discardableResult
    public func sendAppOwnedNamedKeyResult(
        _ keyName: String
    ) -> NamedKeySendResult {
        sendNamedKeyWithOwnership(keyName, recordPromptInput: false)
    }

    @MainActor
    @discardableResult
    private func sendNamedKeyWithOwnership(
        _ keyName: String,
        recordPromptInput: Bool
    ) -> NamedKeySendResult {
        guard let event = pendingKeyEvent(for: keyName) else { return .unknownKey }
        didReceiveExplicitInput()
        let result = sendNamedKeyAfterExplicitInput(
            event,
            recordPromptInput: recordPromptInput
        )
        if result.accepted {
            hibernationRecorder.recordTerminalInput(
                workspaceId: tabId,
                panelId: id
            )
        }
        return result
    }

    @MainActor
    private func sendNamedKeyAfterExplicitInput(
        _ event: PendingKeyEvent,
        recordPromptInput: Bool
    ) -> NamedKeySendResult {
        if deferInputDuringRuntimeClipboardRead(
            estimatedBytes: PendingSocketInput.key(event).estimatedBytes,
            isHumanInput: recordPromptInput,
            replay: { [weak self] in
                _ = self?.sendNamedKeyAfterExplicitInput(
                    event,
                    recordPromptInput: recordPromptInput
                )
            }
        ) {
            return .queued
        }
        guard surface != nil else {
            guard allowsRuntimeSurfaceCreation() else { return .surfaceUnavailable }
            let pendingInput: PendingSocketInput = recordPromptInput
                ? .key(event)
                : .appOwnedKey(event)
            guard enqueuePendingSocketInput(pendingInput) else {
                return .inputQueueFull
            }
            if recordPromptInput {
                promptInputLedger.recordHumanInput(
                    promptInputMutation(for: event)
                )
            }
            requestInputDemandSurfaceStartIfNeeded()
            didAcceptExplicitInput()
            return .queued
        }
        guard let liveSurface = liveSurfaceForSocketWrite(reason: "socket.sendNamedKey") else {
            return .surfaceUnavailable
        }
        guard !ghostty_surface_process_exited(liveSurface) else { return .processExited }
        sendKeyEvent(surface: liveSurface, keycode: event.keycode, mods: event.mods)
        if recordPromptInput {
            promptInputLedger.recordHumanInput(
                promptInputMutation(for: event)
            )
        }
        didAcceptExplicitInput()
        return .sent
    }

    /// Clears the focused terminal's screen while preserving scrollback by sending
    /// Ctrl-L (form-feed) to the running program — exactly as if the user pressed the
    /// key.
    ///
    /// Shells clear the viewport and redraw the prompt while leaving scrollback
    /// intact, and full-screen TUIs (vim, less, …) simply repaint. Because this is
    /// ordinary keyboard input rather than an erase sequence injected through the
    /// PTY-output parser, it never mutates the terminal behind the running program's
    /// back, so it stays safe on the alternate screen. Ghostty's own ^L-at-a-prompt
    /// heuristic scrolls the cleared screen into scrollback when shell prompt markers
    /// are present; unlike `clear_screen` (⌘K), scrollback is never erased.
    ///
    /// - Returns: `true` when the keystroke was delivered or queued for the focused
    ///   terminal, `false` when no live surface could accept it.
    @MainActor
    @discardableResult
    public func clearScreenKeepingScrollback() -> Bool {
        return sendNamedKey("ctrl-l").accepted
    }

    /// The visible viewport text, or nil without a live surface.
    @MainActor
    public func visibleText() -> String? {
        readText(region: .viewport)
    }

    /// Send text with control characters (Return, Tab, etc.) delivered as key
    /// events so the shell processes them, while complete terminal control
    /// sequences are routed through Ghostty's PTY-output parser. Cold surfaces
    /// queue the same ordered events and flush them after runtime creation.
    @MainActor
    @discardableResult
    public func sendInput(_ text: String) -> Bool {
        return sendInputResult(text).accepted
    }

    /// ``sendInput(_:)`` with a structured result.
    @MainActor
    @discardableResult
    public func sendInputResult(_ text: String) -> InputSendResult {
        sendInputResultWithOwnership(text, recordPromptInput: true)
    }

    /// Sends input owned by an app control without recording it as human
    /// composer input.
    ///
    /// Mobile chat answers are terminal control actions, not text typed into
    /// the agent composer. They still use the normal explicit-input and
    /// clipboard sequencing paths, but cannot make a later automation prompt
    /// fail closed as if a human had started a draft.
    @MainActor
    @discardableResult
    public func sendAppOwnedInputResult(_ text: String) -> InputSendResult {
        sendInputResultWithOwnership(text, recordPromptInput: false)
    }

    @MainActor
    @discardableResult
    private func sendInputResultWithOwnership(
        _ text: String,
        recordPromptInput: Bool
    ) -> InputSendResult {
        guard !text.isEmpty else { return .sent }
        didReceiveExplicitInput()
        let result = sendInputAfterExplicitInput(
            text,
            recordPromptInput: recordPromptInput
        )
        if result.accepted {
            hibernationRecorder.recordTerminalInput(
                workspaceId: tabId,
                panelId: id
            )
        }
        return result
    }

    @MainActor
    private func sendInputAfterExplicitInput(
        _ text: String,
        recordPromptInput: Bool
    ) -> InputSendResult {
        let events = Self.parsedSocketInputEvents(for: text)
        if deferInputDuringRuntimeClipboardRead(
            estimatedBytes: text.utf8.count,
            isHumanInput: recordPromptInput,
            replay: { [weak self] in
                _ = self?.sendInputAfterExplicitInput(
                    text,
                    recordPromptInput: recordPromptInput
                )
            }
        ) {
            return .queued
        }
        guard surface != nil else {
            guard allowsRuntimeSurfaceCreation() else { return .surfaceUnavailable }
            let queued = enqueuePendingSocketInput(
                events,
                isHumanInput: recordPromptInput
            )
            if queued {
                if recordPromptInput {
                    recordPromptInputMutations(for: events)
                }
                requestInputDemandSurfaceStartIfNeeded()
                didAcceptExplicitInput()
            }
            return queued ? .queued : .inputQueueFull
        }
        guard let liveSurface = liveSurfaceForSocketWrite(reason: "socket.sendInput") else {
            return .surfaceUnavailable
        }
        guard !ghostty_surface_process_exited(liveSurface) else { return .processExited }
        var validatedSurface: ghostty_surface_t? = liveSurface
        var validatedGeneration: UInt64? = runtimeSurfaceGeneration
        var queuedInput = false
        for input in Self.pendingSocketInputs(
            for: events,
            isHumanInput: recordPromptInput
        ) {
            let deliveryResult = deliverPendingSocketInput(
                input,
                validatedSurface: &validatedSurface,
                validatedGeneration: &validatedGeneration
            )
            if case .deferred = deliveryResult {
                queuedInput = true
            }
        }
        if recordPromptInput {
            recordPromptInputMutations(for: events)
        }
        didAcceptExplicitInput()
        return queuedInput ? .queued : .sent
    }

    /// Atomically delivers one composed prompt as optional app-owned
    /// preparation keys, bracketed-paste text, and exactly one named submit
    /// key.
    ///
    /// Guarded callers require an authoritative agent scope before admission,
    /// so a deferred transaction can never be retargeted to an unknown
    /// process.
    @MainActor
    @discardableResult
    public func sendPromptSubmission(
        _ text: String,
        submitKey: String,
        preparationKeys: [String] = [],
        rejectIfHumanComposerBusy: Bool = true,
        hookRecordingSource: String? = nil,
        hookConfirmsHumanInput: Bool = false,
        recordHumanPromptInput: Bool = false,
        agentInputScope: String? = nil,
        deliveryReceipt: PromptSubmissionDeliveryReceipt? = nil
    ) -> PromptSubmissionSendResult {
        let data = Data(text.utf8)
        guard let submitEvent = pendingKeyEvent(for: submitKey) else {
            deliveryReceipt?.finish(.unknownKey)
            return .unknownKey
        }
        let preparationEvents = preparationKeys.compactMap {
            pendingKeyEvent(for: $0)
        }
        guard preparationEvents.count == preparationKeys.count else {
            deliveryReceipt?.finish(.unknownKey)
            return .unknownKey
        }
        if rejectIfHumanComposerBusy,
           (promptInputLedger.hasUnconfirmedHumanInput
            || hasQueuedHumanPromptSubmission) {
            deliveryReceipt?.finish(.composerBusy)
            return .composerBusy
        }
        if rejectIfHumanComposerBusy,
           surfaceView.hasDeferredHumanInputDuringClipboardRead() {
            deliveryReceipt?.finish(.composerBusy)
            return .composerBusy
        }
        let hookConfirmedHumanInputSnapshot = !recordHumanPromptInput
            && hookConfirmsHumanInput
            ? promptInputLedger.humanInputSnapshot
            : nil
        let validatesAgentScope = !recordHumanPromptInput
            && rejectIfHumanComposerBusy
        let admittedAgentInputScope: String?
        if validatesAgentScope {
            guard let scope = agentInputScope
                    ?? promptInputLedger.currentAgentScope else {
                deliveryReceipt?.finish(.agentScopeUnavailable)
                return .agentScopeUnavailable
            }
            admittedAgentInputScope = scope
        } else {
            admittedAgentInputScope = nil
        }
        let estimatedBytes = preparationEvents.reduce(
            data.count + submitEvent.queuedByteCost
        ) { byteCount, event in
            byteCount + event.queuedByteCost
        }
        let pendingPromptInput: PendingSocketInput = recordHumanPromptInput
            ? .humanPromptSubmission(
                preparationKeys: preparationEvents,
                text: data,
                submitKey: submitEvent
            )
            : .promptSubmission(
                preparationKeys: preparationEvents,
                text: data,
                submitKey: submitEvent,
                hookRecordingSource: hookRecordingSource,
                hookConfirmedHumanInputSnapshot:
                    hookConfirmedHumanInputSnapshot,
                agentInputScope: admittedAgentInputScope,
                deliveryReceipt: deliveryReceipt
            )
        if !deferredPromptSubmissionRetries.isEmpty {
            return .inputQueueFull
        }
        if deliveryReceipt == nil {
            deferredPromptSubmissionRetries = [pendingPromptInput]
            deferredPromptSubmissionRetryBytes = pendingPromptInput.estimatedBytes
            deferredPromptSubmissionRetryRounds = 0
        }

        // Admission captures the human-input generation before the compound
        // transaction can wait behind a runtime clipboard read. The replay
        // closure intentionally calls the post-admission helper directly so
        // it cannot recapture a newer generation or split the transaction.
        if deferInputDuringRuntimeClipboardRead(
            estimatedBytes: estimatedBytes,
            isHumanInput: recordHumanPromptInput,
            replay: { [weak self] in
                guard let self else {
                    deliveryReceipt?.finish(.surfaceUnavailable)
                    return
                }
                let result = self.sendPromptSubmissionAfterAdmission(
                    text,
                    data: data,
                    preparationEvents: preparationEvents,
                    submitEvent: submitEvent,
                    hookRecordingSource: hookRecordingSource,
                    recordHumanPromptInput: recordHumanPromptInput,
                    admittedAgentInputScope: admittedAgentInputScope,
                    hookConfirmedHumanInputSnapshot:
                        hookConfirmedHumanInputSnapshot,
                    deliveryReceipt: deliveryReceipt
                )
                if result == .sent {
                    deliveryReceipt?.finish(.sent)
                    if deliveryReceipt == nil {
                        self.clearDeferredPromptSubmissionRetry()
                    }
                } else if result == .queued {
                    if deliveryReceipt == nil {
                        self.clearDeferredPromptSubmissionRetry()
                    }
                } else if let receiptLessInput =
                            deliveryReceipt == nil ? pendingPromptInput : nil {
                    self.clearDeferredPromptSubmissionRetry()
                    _ = self.retainDeferredPromptSubmission(receiptLessInput)
                    self.requestInputDemandSurfaceStartIfNeeded()
                } else if result != .queued {
                    deliveryReceipt?.finish(result)
                }
            },
            onDiscard: { [weak self] in
                guard let self else {
                    deliveryReceipt?.cancel()
                    return
                }
                if let deliveryReceipt {
                    deliveryReceipt.finish(.surfaceUnavailable)
                } else {
                    self.clearDeferredPromptSubmissionRetry()
                    _ = self.retainDeferredPromptSubmission(
                        pendingPromptInput
                    )
                }
            }
        ) {
            hibernationRecorder.recordTerminalInput(
                workspaceId: tabId,
                panelId: id
            )
            return .queued
        }
        clearDeferredPromptSubmissionRetry()

        let result = sendPromptSubmissionAfterAdmission(
            text,
            data: data,
            preparationEvents: preparationEvents,
            submitEvent: submitEvent,
            hookRecordingSource: hookRecordingSource,
            recordHumanPromptInput: recordHumanPromptInput,
            admittedAgentInputScope: admittedAgentInputScope,
            hookConfirmedHumanInputSnapshot:
                hookConfirmedHumanInputSnapshot,
            deliveryReceipt: deliveryReceipt
        )
        if result != .queued {
            deliveryReceipt?.finish(result)
        }
        if result.accepted {
            hibernationRecorder.recordTerminalInput(
                workspaceId: tabId,
                panelId: id
            )
        }
        return result
    }

    @MainActor
    @discardableResult
    private func sendPromptSubmissionAfterAdmission(
        _ text: String,
        data: Data,
        preparationEvents: [PendingKeyEvent],
        submitEvent: PendingKeyEvent,
        hookRecordingSource: String?,
        recordHumanPromptInput: Bool,
        admittedAgentInputScope: String?,
        hookConfirmedHumanInputSnapshot:
            TerminalPromptInputLedger.HumanInputSnapshot?,
        deliveryReceipt: PromptSubmissionDeliveryReceipt?
    ) -> PromptSubmissionSendResult {
        if deliveryReceipt?.isCancelled == true {
            return .surfaceUnavailable
        }
        if let admittedAgentInputScope,
           promptInputLedger.currentAgentScope != admittedAgentInputScope {
            return .agentScopeUnavailable
        }
        guard surface != nil else {
            guard allowsRuntimeSurfaceCreation() else {
                return .surfaceUnavailable
            }
            let pendingInput: PendingSocketInput = recordHumanPromptInput
                ? .humanPromptSubmission(
                    preparationKeys: preparationEvents,
                    text: data,
                    submitKey: submitEvent
                )
                : .promptSubmission(
                    preparationKeys: preparationEvents,
                    text: data,
                    submitKey: submitEvent,
                    hookRecordingSource: hookRecordingSource,
                    hookConfirmedHumanInputSnapshot:
                        hookConfirmedHumanInputSnapshot,
                    agentInputScope: admittedAgentInputScope,
                    deliveryReceipt: deliveryReceipt
                )
            guard enqueuePendingSocketInput(pendingInput) else {
                return .inputQueueFull
            }
            didReceiveExplicitInput()
            didAcceptExplicitInput()
            requestInputDemandSurfaceStartIfNeeded()
            return .queued
        }
        guard let liveSurface = liveSurfaceForSocketWrite(
            reason: "socket.sendPromptSubmission"
        ) else {
            return .surfaceUnavailable
        }
        guard !ghostty_surface_process_exited(liveSurface) else {
            return .processExited
        }

        guard deliveryReceipt?.beginDelivery() ?? true else {
            return .surfaceUnavailable
        }
        didReceiveExplicitInput()
        for preparationEvent in preparationEvents {
            sendKeyEvent(
                surface: liveSurface,
                keycode: preparationEvent.keycode,
                mods: preparationEvent.mods
            )
        }
        writeTextData(data, to: liveSurface)
        sendKeyEvent(
            surface: liveSurface,
            keycode: submitEvent.keycode,
            mods: submitEvent.mods
        )
        if recordHumanPromptInput {
            recordHumanPromptSubmissionInput(
                preparationEvents: preparationEvents,
                text: data,
                submitEvent: submitEvent
            )
        } else {
            promptInputLedger.recordProgrammaticSubmission(
                message: text,
                source: hookRecordingSource,
                confirmsHumanInputSnapshot:
                    hookConfirmedHumanInputSnapshot
            )
        }
        didAcceptExplicitInput()
        return .sent
    }

    @MainActor
    private func recordHumanPromptSubmissionInput(
        preparationEvents: [PendingKeyEvent],
        text: Data,
        submitEvent: PendingKeyEvent
    ) {
        for _ in preparationEvents {
            promptInputLedger.recordHumanInput(.unknown)
        }
        if !text.isEmpty {
            promptInputLedger.recordHumanInput(.unknown)
        }
        promptInputLedger.recordHumanInput(
            promptInputMutation(for: submitEvent)
        )
    }

    @MainActor
    private func enqueuePendingSocketInput(_ text: String) -> Bool {
        enqueuePendingSocketInput(Self.parsedSocketInputEvents(for: text))
    }

    @MainActor
    private func enqueuePendingSocketInput(
        _ events: [ParsedSocketInput],
        isHumanInput: Bool = true
    ) -> Bool {
        enqueuePendingSocketInputs(
            Self.pendingSocketInputs(
                for: events,
                isHumanInput: isHumanInput
            )
        )
    }

    private static func pendingSocketInputs(
        for text: String,
        isHumanInput: Bool = true
    ) -> [PendingSocketInput] {
        pendingSocketInputs(
            for: parsedSocketInputEvents(for: text),
            isHumanInput: isHumanInput
        )
    }

    private static func pendingSocketInputs(
        for events: [ParsedSocketInput],
        isHumanInput: Bool = true
    ) -> [PendingSocketInput] {
        events.compactMap { event in
            switch event {
            case .rawBytes(let data):
                guard !data.isEmpty else { return nil }
                return isHumanInput
                    ? .inputText(data)
                    : .appOwnedInputText(data)
            case .terminalBytes(let data):
                return data.isEmpty ? nil : .processOutput(data)
            case .key(let event):
                return isHumanInput ? .key(event) : .appOwnedKey(event)
            }
        }
    }

    @MainActor
    private func recordPromptInputMutations(
        for events: [ParsedSocketInput]
    ) {
        for event in events {
            switch event {
            case .rawBytes(let data):
                promptInputLedger.recordHumanInput(
                    data.count == 1 && data.first == 0x0D
                        && !controlReturnIsPromptSubmissionBoundary
                        ? .submissionBoundary
                        : .unknown
                )
            case .key(let event):
                promptInputLedger.recordHumanInput(
                    promptInputMutation(for: event)
                )
            case .terminalBytes:
                break
            }
        }
    }

    @MainActor
    private func promptInputMutation(
        for event: PendingKeyEvent
    ) -> HumanPromptInputMutation {
        promptInputMutation(keycode: event.keycode, mods: event.mods)
    }

    @MainActor
    private func promptInputMutation(
        keycode: UInt32,
        mods: ghostty_input_mods_e
    ) -> HumanPromptInputMutation {
        guard keycode == UInt32(kVK_Return)
                || keycode == UInt32(kVK_ANSI_KeypadEnter) else {
            return .unknown
        }
        let relevantModifierMask =
            GHOSTTY_MODS_SHIFT.rawValue
                | GHOSTTY_MODS_CTRL.rawValue
                | GHOSTTY_MODS_ALT.rawValue
                | GHOSTTY_MODS_SUPER.rawValue
        let relevantModifiers = mods.rawValue & relevantModifierMask
        if relevantModifiers == GHOSTTY_MODS_NONE.rawValue {
            // Claude's multiline composer uses Ctrl-Return as the submit
            // chord. A plain Return inserts an interior line break and must
            // stay unknown so its hook cannot confirm that boundary.
            return controlReturnIsPromptSubmissionBoundary
                ? .unknown
                : .submissionBoundary
        }
        if controlReturnIsPromptSubmissionBoundary,
           relevantModifiers == GHOSTTY_MODS_CTRL.rawValue {
            return .submissionBoundary
        }
        return .unknown
    }

    /// Splits socket text into ordered raw-byte, terminal-byte, and key
    /// events (the socket input grammar).
    public static func parsedSocketInputEvents(for text: String) -> [ParsedSocketInput] {
        guard !text.isEmpty else { return [] }

        var events: [ParsedSocketInput] = []
        events.reserveCapacity(8)
        var bufferedText = ""
        bufferedText.reserveCapacity(text.count)
        var previousWasCR = false
        let scalars = Array(text.unicodeScalars)

        func flushBufferedText() {
            guard !bufferedText.isEmpty else { return }
            for chunk in committedTextInputChunks(from: bufferedText) {
                events.append(.rawBytes(chunk))
            }
            bufferedText.removeAll(keepingCapacity: true)
        }

        func appendKey(_ keycode: UInt32, mods: ghostty_input_mods_e = GHOSTTY_MODS_NONE, label: String) {
            events.append(.key(PendingKeyEvent(
                keycode: keycode,
                mods: mods,
                label: label
            )))
        }

        func appendRawReturn() {
            events.append(.rawBytes(Data([0x0D])))
        }

        func appendTerminalBytes(length: Int, from start: Int) {
            guard length > 0 else { return }
            var sequence = ""
            for offset in start..<(start + length) {
                sequence.unicodeScalars.append(scalars[offset])
            }
            guard let data = sequence.data(using: .utf8), !data.isEmpty else { return }
            events.append(.terminalBytes(data))
        }

        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            switch scalar.value {
            case 0x0A:
                if !previousWasCR {
                    flushBufferedText()
                    appendRawReturn()
                }
                previousWasCR = false
                index += 1
            case 0x0D:
                flushBufferedText()
                appendRawReturn()
                previousWasCR = true
                index += 1
            case 0x09:
                flushBufferedText()
                appendKey(UInt32(kVK_Tab), label: "tab")
                previousWasCR = false
                index += 1
            case 0x1B:
                // A bare ESC is the Escape key. But a full CSI/SS3 navigation
                // sequence arriving as raw input (the iOS on-screen arrows send
                // ESC[B, etc.) must stay one key press, or the terminal receives
                // Escape followed by literal "[B". Re-issue recognized sequences
                // as key events so libghostty encodes them for the surface's
                // current cursor-key mode, exactly like a hardware arrow press.
                if let nav = navigationEscapeKey(scalars, from: index) {
                    flushBufferedText()
                    appendKey(nav.keycode, mods: nav.mods, label: nav.label)
                    index += nav.length
                } else if let length = terminalControlSequenceLength(scalars, from: index) {
                    flushBufferedText()
                    appendTerminalBytes(length: length, from: index)
                    index += length
                } else {
                    flushBufferedText()
                    appendKey(UInt32(kVK_Escape), label: "escape")
                    index += 1
                }
                previousWasCR = false
            case 0x08, 0x7F:
                flushBufferedText()
                appendKey(UInt32(kVK_Delete), label: "backspace")
                previousWasCR = false
                index += 1
            default:
                bufferedText.unicodeScalars.append(scalar)
                previousWasCR = false
                index += 1
            }
        }
        flushBufferedText()
        return events
    }

    /// Returns the byte-like scalar length for a complete terminal string control sequence.
    private static func terminalControlSequenceLength(
        _ scalars: [Unicode.Scalar],
        from start: Int
    ) -> Int? {
        guard start + 1 < scalars.count, scalars[start].value == 0x1B else { return nil }

        switch scalars[start + 1].value {
        case 0x5D: // OSC: ESC ] ... (BEL | ST)
            return stringControlSequenceLength(scalars, from: start, terminatesWithBEL: true)
        case 0x50, 0x5E, 0x5F: // DCS / PM / APC: ESC P/^/_ ... ST
            return stringControlSequenceLength(scalars, from: start, terminatesWithBEL: false)
        default:
            return nil
        }
    }

    /// Finds the terminator for ESC-prefixed string controls without accepting partial sequences.
    private static func stringControlSequenceLength(
        _ scalars: [Unicode.Scalar],
        from start: Int,
        terminatesWithBEL: Bool
    ) -> Int? {
        var index = start + 2
        while index < scalars.count {
            let value = scalars[index].value
            if terminatesWithBEL, value == 0x07 {
                return index - start + 1
            }
            if value == 0x1B,
               index + 1 < scalars.count,
               scalars[index + 1].value == 0x5C {
                return index - start + 2
            }
            index += 1
        }
        return nil
    }

    /// Match a CSI (`ESC [ …`) or SS3 (`ESC O …`) cursor/navigation escape
    /// sequence beginning at `start` (which points at the ESC, 0x1B). Returns
    /// the equivalent macOS key code and how many scalars the sequence consumed,
    /// or nil for a bare ESC or an unrecognized sequence (which stays the
    /// Escape key). Only unmodified navigation keys are mapped; the surface
    /// re-encodes them for its current DECCKM cursor-key mode.
    private static func navigationEscapeKey(
        _ scalars: [Unicode.Scalar],
        from start: Int
    ) -> (keycode: UInt32, mods: ghostty_input_mods_e, label: String, length: Int)? {
        guard start + 1 < scalars.count else { return nil }
        let next = scalars[start + 1].value
        // Meta+Backspace: the iOS app sends ESC 0x7F (or ESC 0x08) for
        // option-delete-word. Re-issue as Backspace with the Option modifier so
        // libghostty encodes the meta-backspace for the surface, instead of the
        // bare-ESC path splitting it into Escape + a plain backspace.
        if next == 0x7F || next == 0x08 {
            return (UInt32(kVK_Delete), GHOSTTY_MODS_ALT, "alt-backspace", 2)
        }
        // CSI (ESC[) / SS3 (ESCO) cursor + navigation sequences.
        guard next == 0x5B || next == 0x4F, start + 2 < scalars.count else { return nil }
        let final = scalars[start + 2].value
        switch final {
        case 0x41: return (UInt32(kVK_UpArrow), GHOSTTY_MODS_NONE, "up", 3)        // A
        case 0x42: return (UInt32(kVK_DownArrow), GHOSTTY_MODS_NONE, "down", 3)    // B
        case 0x43: return (UInt32(kVK_RightArrow), GHOSTTY_MODS_NONE, "right", 3)  // C
        case 0x44: return (UInt32(kVK_LeftArrow), GHOSTTY_MODS_NONE, "left", 3)    // D
        case 0x48: return (UInt32(kVK_Home), GHOSTTY_MODS_NONE, "home", 3)         // H
        case 0x46: return (UInt32(kVK_End), GHOSTTY_MODS_NONE, "end", 3)           // F
        default:
            break
        }
        // CSI tilde sequences: ESC [ N ~
        if next == 0x5B, start + 3 < scalars.count, scalars[start + 3].value == 0x7E {
            switch final {
            case 0x31: return (UInt32(kVK_Home), GHOSTTY_MODS_NONE, "home", 4)               // 1~
            case 0x33: return (UInt32(kVK_ForwardDelete), GHOSTTY_MODS_NONE, "forwardDelete", 4) // 3~
            case 0x34: return (UInt32(kVK_End), GHOSTTY_MODS_NONE, "end", 4)                 // 4~
            case 0x35: return (UInt32(kVK_PageUp), GHOSTTY_MODS_NONE, "pageUp", 4)           // 5~
            case 0x36: return (UInt32(kVK_PageDown), GHOSTTY_MODS_NONE, "pageDown", 4)       // 6~
            default:
                break
            }
        }
        return nil
    }

    private static func committedTextInputChunks(from text: String) -> [Data] {
        guard !text.isEmpty else { return [] }

        var chunks: [Data] = []
        chunks.reserveCapacity(max(1, (text.utf8.count / committedTextInputChunkByteLimit) + 1))
        var chunk = Data()
        chunk.reserveCapacity(committedTextInputChunkByteLimit)

        func flushChunk() {
            guard !chunk.isEmpty else { return }
            chunks.append(chunk)
            chunk.removeAll(keepingCapacity: true)
        }

        for scalar in text.unicodeScalars {
            let scalarBytes = String(scalar).utf8
            if !chunk.isEmpty, chunk.count + scalarBytes.count > committedTextInputChunkByteLimit {
                flushChunk()
            }
            chunk.append(contentsOf: scalarBytes)
        }
        flushChunk()
        return chunks
    }

    // Canonical key text for synthetic key events sent from the mobile/socket
    // input path (see `sendKeyEvent`). The desktop `keyDown` handler fills
    // `ghostty_input_key_s.text` from `charactersIgnoringModifiers`; libghostty
    // needs that text to encode control keys whose byte is otherwise filtered by
    // the raw-text input path. Mobile builds the event from a bare keycode, so we
    // reproduce the same canonical text here, keyed purely off the keycode.
    //
    // Only Backspace/Delete and Tab need this: their physical macOS keys carry
    // the DEL (0x7F) and TAB (0x09) characters in `charactersIgnoringModifiers`.
    // The text is independent of modifiers (Option-Backspace still reports DEL),
    // so this intentionally ignores `mods`. Pure function keys (arrows, Home,
    // End, page navigation) carry no characters and correctly encode from the
    // keycode alone, so they return nil.
    private static func canonicalKeyText(keycode: UInt32) -> String? {
        switch keycode {
        case UInt32(kVK_Delete):
            return "\u{7F}"
        case UInt32(kVK_Tab):
            return "\t"
        default:
            return nil
        }
    }

    @MainActor
    func sendKeyEvent(
        surface: ghostty_surface_t,
        keycode: UInt32,
        mods: ghostty_input_mods_e = GHOSTTY_MODS_NONE
    ) {
        var keyEvent = ghostty_input_key_s()
        keyEvent.action = GHOSTTY_ACTION_PRESS
        keyEvent.keycode = keycode
        keyEvent.mods = mods
        keyEvent.consumed_mods = GHOSTTY_MODS_NONE
        keyEvent.composing = false

        let canonicalText = Self.canonicalKeyText(keycode: keycode)
        keyEvent.unshifted_codepoint = canonicalText?.unicodeScalars.first?.value ?? 0

        let handled: Bool
        if let canonicalText {
            // Mirror the desktop `keyDown` path's C-string lifetime: the text
            // pointer must stay valid only for the `ghostty_surface_key` call.
            handled = canonicalText.withCString { ptr in
                keyEvent.text = ptr
                return withRuntimeClipboardPasteIntent {
                    ghostty_surface_key(surface, keyEvent)
                }
            }
        } else {
            keyEvent.text = nil
            handled = withRuntimeClipboardPasteIntent {
                ghostty_surface_key(surface, keyEvent)
            }
        }

#if DEBUG
        logDebugEvent(
            "surface.socket_input.key surface=\(id.uuidString.prefix(8)) " +
            "keycode=\(keycode) mods=\(mods.rawValue) " +
            "codepoint=0x\(String(keyEvent.unshifted_codepoint, radix: 16)) " +
            "handled=\(handled ? 1 : 0)"
        )
#endif
    }

    @MainActor
    private func liveSurfaceForSocketWrite(reason: String) -> ghostty_surface_t? {
        return liveSurfaceForGhosttyAccess(reason: reason)
    }

    func writeTextData(_ data: Data, to surface: ghostty_surface_t) {
        data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress?.assumingMemoryBound(to: CChar.self) else { return }
            ghostty_surface_text(surface, baseAddress, UInt(rawBuffer.count))
        }
    }

    func writeInputTextData(_ data: Data, to surface: ghostty_surface_t) {
        data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress?.assumingMemoryBound(to: CChar.self) else { return }
            ghostty_surface_text_input(surface, baseAddress, UInt(rawBuffer.count))
        }
    }

    /// Sends bytes through Ghostty's PTY-output parser so OSC commands affect terminal state.
    func writeProcessOutputData(_ data: Data, to surface: ghostty_surface_t) {
        data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress?.assumingMemoryBound(to: CChar.self) else { return }
            ghostty_surface_process_output(surface, baseAddress, UInt(rawBuffer.count))
        }
    }

    /// Sets whether a manual-I/O surface should suppress Ghostty's primary
    /// screen reflow on resize. Remote tmux marks TUI/alt-screen panes true and
    /// plain shell panes false.
    @MainActor
    public func setManualIONoReflow(_ value: Bool) {
        guard manualIONoReflow != value else { return }
        manualIONoReflow = value
    }

    /// Enqueues remote tmux `%output` for the terminal parser.
    ///
    /// The native parser runs on the surface generation's FIFO output lane and
    /// this method returns without waiting for Ghostty's renderer-state mutex.
    /// If the runtime is not live yet, a bounded tail is buffered and flushed on
    /// creation.
    @MainActor
    public func processRemoteOutput(_ data: Data) {
        guard !data.isEmpty else { return }
        guard let surface = liveSurfaceForGhosttyAccess(reason: "remoteOutput") else {
            pendingRemoteOutput.append(data)
            if pendingRemoteOutput.count > maxPendingRemoteOutputBytes {
                pendingRemoteOutput.removeFirst(pendingRemoteOutput.count - maxPendingRemoteOutputBytes)
            }
            return
        }
        flushPendingRemoteOutput(to: surface)
        remoteOutputLane.enqueue(data, to: surface)
    }

    @MainActor
    func flushPendingRemoteOutput(to surface: ghostty_surface_t) {
        guard !pendingRemoteOutput.isEmpty else { return }
        let buffered = pendingRemoteOutput
        pendingRemoteOutput = Data()
        remoteOutputLane.enqueue(buffered, to: surface)
    }

    private func keycodeForLetter(_ letter: Character) -> UInt32? {
        switch String(letter).lowercased() {
        case "a": return UInt32(kVK_ANSI_A)
        case "b": return UInt32(kVK_ANSI_B)
        case "c": return UInt32(kVK_ANSI_C)
        case "d": return UInt32(kVK_ANSI_D)
        case "e": return UInt32(kVK_ANSI_E)
        case "f": return UInt32(kVK_ANSI_F)
        case "g": return UInt32(kVK_ANSI_G)
        case "h": return UInt32(kVK_ANSI_H)
        case "i": return UInt32(kVK_ANSI_I)
        case "j": return UInt32(kVK_ANSI_J)
        case "k": return UInt32(kVK_ANSI_K)
        case "l": return UInt32(kVK_ANSI_L)
        case "m": return UInt32(kVK_ANSI_M)
        case "n": return UInt32(kVK_ANSI_N)
        case "o": return UInt32(kVK_ANSI_O)
        case "p": return UInt32(kVK_ANSI_P)
        case "q": return UInt32(kVK_ANSI_Q)
        case "r": return UInt32(kVK_ANSI_R)
        case "s": return UInt32(kVK_ANSI_S)
        case "t": return UInt32(kVK_ANSI_T)
        case "u": return UInt32(kVK_ANSI_U)
        case "v": return UInt32(kVK_ANSI_V)
        case "w": return UInt32(kVK_ANSI_W)
        case "x": return UInt32(kVK_ANSI_X)
        case "y": return UInt32(kVK_ANSI_Y)
        case "z": return UInt32(kVK_ANSI_Z)
        default: return nil
        }
    }

    private func keycodeForNamedKey(_ name: String) -> UInt32? {
        switch name {
        case "enter", "return": return UInt32(kVK_Return)
        case "tab": return UInt32(kVK_Tab)
        case "escape", "esc": return UInt32(kVK_Escape)
        case "backspace": return UInt32(kVK_Delete)
        case "delete": return UInt32(kVK_ForwardDelete)
        case "space": return UInt32(kVK_Space)
        case "up": return UInt32(kVK_UpArrow)
        case "down": return UInt32(kVK_DownArrow)
        case "left": return UInt32(kVK_LeftArrow)
        case "right": return UInt32(kVK_RightArrow)
        case "\\": return UInt32(kVK_ANSI_Backslash)
        default: return nil
        }
    }

    func pendingKeyEvent(for keyName: String) -> PendingKeyEvent? {
        let normalized = keyName.lowercased()
        switch normalized {
        case "ctrl-c", "ctrl+c", "sigint":
            return PendingKeyEvent(keycode: UInt32(kVK_ANSI_C), mods: GHOSTTY_MODS_CTRL, label: normalized)
        case "ctrl-d", "ctrl+d", "eof":
            return PendingKeyEvent(keycode: UInt32(kVK_ANSI_D), mods: GHOSTTY_MODS_CTRL, label: normalized)
        case "ctrl-f", "ctrl+f":
            // Force-stop chord for embedded TUIs (e.g. Claude Code's "Ctrl-F twice").
            return PendingKeyEvent(keycode: UInt32(kVK_ANSI_F), mods: GHOSTTY_MODS_CTRL, label: normalized)
        case "ctrl-z", "ctrl+z", "sigtstp":
            return PendingKeyEvent(keycode: UInt32(kVK_ANSI_Z), mods: GHOSTTY_MODS_CTRL, label: normalized)
        case "ctrl-\\", "ctrl+\\", "sigquit":
            return PendingKeyEvent(keycode: UInt32(kVK_ANSI_Backslash), mods: GHOSTTY_MODS_CTRL, label: normalized)
        case "enter", "return":
            return PendingKeyEvent(keycode: UInt32(kVK_Return), mods: GHOSTTY_MODS_NONE, label: normalized)
        case "tab":
            return PendingKeyEvent(keycode: UInt32(kVK_Tab), mods: GHOSTTY_MODS_NONE, label: normalized)
        case "escape", "esc":
            return PendingKeyEvent(keycode: UInt32(kVK_Escape), mods: GHOSTTY_MODS_NONE, label: normalized)
        case "backspace":
            return PendingKeyEvent(keycode: UInt32(kVK_Delete), mods: GHOSTTY_MODS_NONE, label: normalized)
        case "up", "arrow_up", "arrowup":
            return PendingKeyEvent(keycode: UInt32(kVK_UpArrow), mods: GHOSTTY_MODS_NONE, label: normalized)
        case "down", "arrow_down", "arrowdown":
            return PendingKeyEvent(keycode: UInt32(kVK_DownArrow), mods: GHOSTTY_MODS_NONE, label: normalized)
        case "left", "arrow_left", "arrowleft":
            return PendingKeyEvent(keycode: UInt32(kVK_LeftArrow), mods: GHOSTTY_MODS_NONE, label: normalized)
        case "right", "arrow_right", "arrowright":
            return PendingKeyEvent(keycode: UInt32(kVK_RightArrow), mods: GHOSTTY_MODS_NONE, label: normalized)
        case "shift+tab", "shift-tab", "backtab":
            return PendingKeyEvent(keycode: UInt32(kVK_Tab), mods: GHOSTTY_MODS_SHIFT, label: normalized)
        case "home":
            return PendingKeyEvent(keycode: UInt32(kVK_Home), mods: GHOSTTY_MODS_NONE, label: normalized)
        case "end":
            return PendingKeyEvent(keycode: UInt32(kVK_End), mods: GHOSTTY_MODS_NONE, label: normalized)
        case "delete", "del", "forward_delete":
            return PendingKeyEvent(keycode: UInt32(kVK_ForwardDelete), mods: GHOSTTY_MODS_NONE, label: normalized)
        case "pageup", "page_up":
            return PendingKeyEvent(keycode: UInt32(kVK_PageUp), mods: GHOSTTY_MODS_NONE, label: normalized)
        case "pagedown", "page_down":
            return PendingKeyEvent(keycode: UInt32(kVK_PageDown), mods: GHOSTTY_MODS_NONE, label: normalized)
        default:
            let parts = normalized
                .split(separator: "+")
                .flatMap { $0.split(separator: "-") }
                .map(String.init)
                .filter { !$0.isEmpty }
            guard let baseKey = parts.last else { return nil }

            if parts.count == 1 {
                if let keycode = keycodeForNamedKey(baseKey) {
                    return PendingKeyEvent(keycode: keycode, mods: GHOSTTY_MODS_NONE, label: normalized)
                }
                if baseKey.count == 1,
                   let char = baseKey.first,
                   let keycode = keycodeForLetter(char) {
                    return PendingKeyEvent(keycode: keycode, mods: GHOSTTY_MODS_NONE, label: normalized)
                }
                return nil
            }

            var mods = GHOSTTY_MODS_NONE
            for mod in parts.dropLast() {
                switch mod {
                case "ctrl", "control":
                    mods = ghostty_input_mods_e(rawValue: mods.rawValue | GHOSTTY_MODS_CTRL.rawValue)
                case "shift":
                    mods = ghostty_input_mods_e(rawValue: mods.rawValue | GHOSTTY_MODS_SHIFT.rawValue)
                case "alt", "opt", "option":
                    mods = ghostty_input_mods_e(rawValue: mods.rawValue | GHOSTTY_MODS_ALT.rawValue)
                case "cmd", "command", "super":
                    mods = ghostty_input_mods_e(rawValue: mods.rawValue | GHOSTTY_MODS_SUPER.rawValue)
                default:
                    return nil
                }
            }

            if let keycode = keycodeForNamedKey(baseKey) {
                return PendingKeyEvent(keycode: keycode, mods: mods, label: normalized)
            }
            if baseKey.count == 1,
               let char = baseKey.first,
               let keycode = keycodeForLetter(char) {
                return PendingKeyEvent(keycode: keycode, mods: mods, label: normalized)
            }
            return nil
        }
    }

    @MainActor
    private func enqueuePendingSocketInput(_ input: PendingSocketInput) -> Bool {
        enqueuePendingSocketInputs([input])
    }

    @MainActor
    func enqueuePendingSocketInputs(_ inputs: [PendingSocketInput]) -> Bool {
        let incomingBytes = inputs.reduce(0) { $0 + $1.estimatedBytes }
        guard incomingBytes > 0 else { return true }

        guard incomingBytes <= maxPendingSocketInputBytes,
              pendingSocketInputBytes + incomingBytes <= maxPendingSocketInputBytes else {
#if DEBUG
            logDebugEvent(
                "surface.socket_input.reject surface=\(id.uuidString.prefix(8)) " +
                "items=\(inputs.count) incomingBytes=\(incomingBytes) pendingBytes=\(pendingSocketInputBytes)"
            )
#endif
            return false
        }

        pendingSocketInputQueue.append(contentsOf: inputs)
        pendingSocketInputBytes += incomingBytes
#if DEBUG
        let pendingKeys = pendingSocketInputQueue.reduce(into: 0) { count, item in
            if case .key = item {
                count += 1
            } else if case .appOwnedKey = item {
                count += 1
            }
        }
        logDebugEvent(
            "surface.socket_input.queue surface=\(id.uuidString.prefix(8)) items=\(pendingSocketInputQueue.count) " +
            "keys=\(pendingKeys) bytes=\(pendingSocketInputBytes)"
        )
#endif
        return true
    }

    /// Drops pending input because this surface will not receive another
    /// runtime write, completing any agent-submit receipts instead of leaving
    /// the global socket lane occupied forever.
    @MainActor
    func discardPendingSocketInput(
        with result: PromptSubmissionSendResult = .surfaceUnavailable
    ) {
        let queued = pendingSocketInputQueue
            + deferredPromptSubmissionRetries
        pendingSocketInputQueue.removeAll(keepingCapacity: false)
        pendingSocketInputBytes = 0
        deferredPromptSubmissionRetries.removeAll(keepingCapacity: false)
        deferredPromptSubmissionRetryBytes = 0
        deferredPromptSubmissionRetryRounds = 0
        for input in queued {
            finishPendingPromptDelivery(input, with: result)
        }
    }

    @MainActor
    private func clearDeferredPromptSubmissionRetry() {
        deferredPromptSubmissionRetries.removeAll(keepingCapacity: false)
        deferredPromptSubmissionRetryBytes = 0
        deferredPromptSubmissionRetryRounds = 0
    }

    @MainActor
    @discardableResult
    private func retainDeferredPromptSubmission(
        _ input: PendingSocketInput
    ) -> Bool {
        let bytes = input.estimatedBytes
        guard deferredPromptSubmissionRetries.count
                < maxDeferredPromptSubmissionRetries,
              bytes <= maxPendingSocketInputBytes,
              deferredPromptSubmissionRetryBytes + bytes
                <= maxPendingSocketInputBytes else {
            return false
        }
        if deferredPromptSubmissionRetries.isEmpty {
            deferredPromptSubmissionRetryRounds = max(
                1,
                deferredPromptSubmissionRetryRounds
            )
        }
        deferredPromptSubmissionRetries.append(input)
        deferredPromptSubmissionRetryBytes += bytes
        return true
    }

    @MainActor
    func flushPendingSocketInputIfNeeded() {
        guard let liveSurface = liveSurfaceForSocketWrite(
            reason: "socket.flushPendingInput"
        ) else {
            return
        }
        if !deferredPromptSubmissionRetries.isEmpty {
            if deferredPromptSubmissionRetryRounds >= 3 {
                let expired = deferredPromptSubmissionRetries
                clearDeferredPromptSubmissionRetry()
                for input in expired {
                    finishPendingPromptDelivery(
                        input,
                        with: .agentScopeUnavailable
                    )
                }
#if DEBUG
                logDebugEvent(
                    "surface.socket_input.expire_deferred_prompt surface=\(id.uuidString.prefix(8)) " +
                    "items=\(expired.count)"
                )
#endif
            } else {
                deferredPromptSubmissionRetryRounds += 1
            }
        }
        let queued = deferredPromptSubmissionRetries
            + pendingSocketInputQueue
        let queuedBytes = pendingSocketInputBytes
        pendingSocketInputQueue.removeAll(keepingCapacity: false)
        pendingSocketInputBytes = 0
        deferredPromptSubmissionRetries.removeAll(keepingCapacity: false)
        deferredPromptSubmissionRetryBytes = 0
        guard !queued.isEmpty else { return }

        var validatedSurface: ghostty_surface_t? = liveSurface
        var validatedGeneration: UInt64? = runtimeSurfaceGeneration
        var queuedKeys = 0
        var retainedItems: [PendingSocketInput] = []
        for (index, item) in queued.enumerated() {
            if case .key = item {
                queuedKeys += 1
            } else if case .appOwnedKey = item {
                queuedKeys += 1
            }
            let deliveryResult = deliverPendingSocketInput(
                item,
                validatedSurface: &validatedSurface,
                validatedGeneration: &validatedGeneration
            )
            if case .failed = deliveryResult,
               shouldRetainPendingPromptAfterFailure(item) {
                retainedItems.append(item)
                // A receipt-less prompt that cannot replay is still the
                // oldest admitted transaction. Keep the untouched suffix
                // behind it instead of allowing later prompts to overtake it.
                retainedItems.append(contentsOf: queued.dropFirst(index + 1))
                break
            }
        }
        if !retainedItems.isEmpty {
            // Keep an admitted prompt available for the original process
            // scope instead of silently dropping a caller-visible `queued`
            // transaction after a restart/rebind.
            for item in retainedItems {
                guard retainDeferredPromptSubmission(item) else { break }
            }
        }
        if deferredPromptSubmissionRetries.isEmpty,
           retainedItems.isEmpty {
            deferredPromptSubmissionRetryRounds = 0
        }
#if DEBUG
        logDebugEvent(
            "surface.socket_input.flush surface=\(id.uuidString.prefix(8)) items=\(queued.count) " +
            "keys=\(queuedKeys) bytes=\(queuedBytes)"
        )
#endif
    }

    @MainActor
    private func shouldRetainPendingPromptAfterFailure(
        _ input: PendingSocketInput
    ) -> Bool {
        switch input {
        case .promptSubmission(
            _, _, _, _, _, _, let deliveryReceipt
        ):
            guard deliveryReceipt == nil,
                  !input.isCancelledPromptSubmission else {
                return false
            }
            return true
        case .humanPromptSubmission:
            return true
        default:
            return false
        }
    }

    @MainActor
    @discardableResult
    private func deliverPendingSocketInput(
        _ input: PendingSocketInput
    ) -> PendingSocketInputDeliveryResult {
        var validatedSurface: ghostty_surface_t?
        var validatedGeneration: UInt64?
        return deliverPendingSocketInput(
            input,
            validatedSurface: &validatedSurface,
            validatedGeneration: &validatedGeneration
        )
    }

    @MainActor
    @discardableResult
    private func deliverPendingSocketInput(
        _ input: PendingSocketInput,
        validatedSurface: inout ghostty_surface_t?,
        validatedGeneration: inout UInt64?
    ) -> PendingSocketInputDeliveryResult {
        guard !input.isCancelledPromptSubmission else {
            return .failed
        }
        if deferInputDuringRuntimeClipboardRead(
            estimatedBytes: input.estimatedBytes,
            isHumanInput: input.isHumanInput,
            replay: { [weak self] in
                guard let self else {
                    input.completePromptSubmissionDelivery(
                        with: .surfaceUnavailable
                    )
                    return
                }
                let deliveryResult = self.deliverPendingSocketInput(input)
                if case .failed = deliveryResult,
                   self.shouldRetainPendingPromptAfterFailure(input) {
                    _ = self.retainDeferredPromptSubmission(input)
                }
            },
            onDiscard: { [weak self] in
                guard let self else {
                    input.completePromptSubmissionDelivery(
                        with: .surfaceUnavailable
                    )
                    return
                }
                if self.shouldRetainPendingPromptAfterFailure(input) {
                    _ = self.retainDeferredPromptSubmission(input)
                } else {
                    input.completePromptSubmissionDelivery(
                        with: .surfaceUnavailable
                    )
                }
            }
        ) {
            return .deferred
        }
        let surface: ghostty_surface_t
        if let cachedSurface = validatedSurface,
           let cachedGeneration = validatedGeneration,
           cachedGeneration == runtimeSurfaceGeneration,
           self.surface == cachedSurface {
            surface = cachedSurface
        } else {
            guard let currentSurface = liveSurfaceForSocketWrite(
                reason: "socket.flushPendingInput.item"
            ) else {
                finishPendingPromptDelivery(
                    input,
                    with: .surfaceUnavailable
                )
                validatedSurface = nil
                validatedGeneration = nil
                return .failed
            }
            surface = currentSurface
            validatedSurface = currentSurface
            validatedGeneration = runtimeSurfaceGeneration
        }
        if case .promptSubmission = input,
           ghostty_surface_process_exited(surface) {
            finishPendingPromptDelivery(input, with: .processExited)
            return .failed
        }
        switch input {
        case .pasteText(let chunk):
            writeTextData(chunk, to: surface)
        case .inputText(let chunk):
            writeInputTextData(chunk, to: surface)
        case .appOwnedInputText(let chunk):
            writeInputTextData(chunk, to: surface)
        case .processOutput(let chunk):
            writeProcessOutputData(chunk, to: surface)
        case .key(let event):
            sendKeyEvent(
                surface: surface,
                keycode: event.keycode,
                mods: event.mods
            )
        case .appOwnedKey(let event):
            sendKeyEvent(
                surface: surface,
                keycode: event.keycode,
                mods: event.mods
            )
        case .promptSubmission(
            let preparationKeys,
            let text,
            let submitKey,
            let hookRecordingSource,
            let hookConfirmedHumanInputSnapshot,
            let admittedAgentInputScope,
            let deliveryReceipt
        ):
            if let admittedAgentInputScope,
               promptInputLedger.currentAgentScope != admittedAgentInputScope {
                deliveryReceipt?.finish(.agentScopeUnavailable)
                return .failed
            }
            guard deliveryReceipt?.beginDelivery() ?? true else {
                return .failed
            }
            for preparationKey in preparationKeys {
                sendKeyEvent(
                    surface: surface,
                    keycode: preparationKey.keycode,
                    mods: preparationKey.mods
                )
            }
            writeTextData(text, to: surface)
            sendKeyEvent(
                surface: surface,
                keycode: submitKey.keycode,
                mods: submitKey.mods
            )
            promptInputLedger.recordProgrammaticSubmission(
                message: String(decoding: text, as: UTF8.self),
                source: hookRecordingSource,
                confirmsHumanInputSnapshot:
                    hookConfirmedHumanInputSnapshot
            )
            deliveryReceipt?.finish(.sent)
        case .humanPromptSubmission(
            let preparationKeys,
            let text,
            let submitKey
        ):
            for preparationKey in preparationKeys {
                sendKeyEvent(
                    surface: surface,
                    keycode: preparationKey.keycode,
                    mods: preparationKey.mods
                )
            }
            writeTextData(text, to: surface)
            sendKeyEvent(
                surface: surface,
                keycode: submitKey.keycode,
                mods: submitKey.mods
            )
            recordHumanPromptSubmissionInput(
                preparationEvents: preparationKeys,
                text: text,
                submitEvent: submitKey
            )
        case .keyText(let text):
            _ = sendKeyText(text, to: surface)
        }
        return .delivered
    }

    @MainActor
    private func finishPendingPromptDelivery(
        _ input: PendingSocketInput,
        with result: PromptSubmissionSendResult
    ) {
        input.completePromptSubmissionDelivery(with: result)
    }
}
