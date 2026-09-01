import Foundation
import GhosttyKit

extension TerminalSurface {
    /// Returns the generation of the provider-specific PTY output detectors.
    ///
    /// The value changes whenever the runtime surface is replaced or a
    /// coordinator requests a parser reset. App-level consumers use it to
    /// reject output that was queued by an older runtime surface.
    ///
    /// - Returns: The current monotonically increasing detector generation.
    @MainActor
    public func currentContextPressureDetectorGeneration() -> UInt64 {
        contextPressureDetectorGeneration
    }

    /// Enables pressure parsing only while this surface has an eligible,
    /// authoritative managed-agent binding.
    ///
    /// The flag is consumed by the serialized PTY tee callback and avoids
    /// decoding and scanning output from ordinary or unmanaged terminals.
    /// Detection/reporting remains enabled when the user disables automated
    /// recovery; the coordinator's policy separately gates PTY writes.
    /// - Parameter enabled: Whether this surface is eligible for detection.
    @MainActor
    public func setContextPressureMonitoringEnabled(_ enabled: Bool) {
        contextPressureMonitoringEnabled = enabled
        mobileByteTeeLease?.setContextPressureMonitoringEnabled(enabled)
    }

    /// Selects the one provider detector eligible for this surface's PTY
    /// output. A nil value clears the selection while an ownership transfer is
    /// in flight.
    ///
    /// - Parameter provider: The managed-agent kind (`claude` or `codex`), or nil.
    @MainActor
    public func setContextPressureProvider(_ provider: String?) {
        let normalized = provider?.trimmingCharacters(in: .whitespacesAndNewlines)
        contextPressureProvider = normalized?.isEmpty == true ? nil : normalized
        mobileByteTeeLease?.setContextPressureProvider(contextPressureProvider)
    }

    /// Notifies the current panel owner after explicit terminal input is accepted.
    @MainActor
    public func didAcceptExplicitInput() {
        onExplicitInput?()
    }

    /// Cancels pending context recovery for a real user event whose terminal
    /// write is deliberately delivered later by another sequencer.
    @MainActor
    public func didObserveUserInitiatedInput() {
        onUserExplicitInput?()
    }

    /// Publishes accepted user intent without duplicating the pane-host input
    /// notification already sent by the shared write API.
    @MainActor
    func didAcceptUserInitiatedInput(_ isUserInitiated: Bool, accepted: Bool) {
        if isUserInitiated, accepted {
            didObserveUserInitiatedInput()
        }
    }

    /// Sends cmux-authored recovery input only when it can reach the live PTY immediately.
    ///
    /// Recovery input never enters the cold-surface or clipboard deferral queues. Returning
    /// `false` leaves the pressure state intact so a later authoritative lifecycle signal can
    /// retry without allowing automation to overtake user input.
    ///
    /// - Parameter text: Text, including a provider-specific Return character, to send.
    /// - Returns: Whether the text was delivered synchronously to the live PTY.
    @MainActor
    @discardableResult
    public func sendContextManagementInput(_ text: String) -> Bool {
        guard !text.isEmpty,
              surface != nil,
              surfaceView.canAcceptImmediateContextManagementInput else {
            return false
        }
        paneHost.terminalSurfaceDidReceiveExplicitInput()
        let result = sendInputToLiveSurfaceAfterExplicitInput(
            text,
            allowClipboardDeferral: false
        )
        if result == .sent {
            hibernationRecorder.recordTerminalInput(
                workspaceId: tabId,
                panelId: id
            )
        }
        return result == .sent
    }

    /// Requests a PTY-tee parser reset before the next output chunk.
    ///
    /// Recovery input can produce the same warning text that triggered it.
    /// Resetting at the tee boundary clears prior occurrence counts without
    /// racing the serialized output callback.
    ///
    /// - Returns: The new detector generation published to the tee lease.
    @MainActor
    @discardableResult
    public func resetContextPressureDetectors() -> UInt64 {
        contextPressureDetectorGeneration &+= 1
        mobileByteTeeLease?.resetContextPressureDetectors(
            to: contextPressureDetectorGeneration
        )
        return contextPressureDetectorGeneration
    }

    @MainActor
    func sendInputAfterExplicitInput(_ text: String) -> InputSendResult {
        if deferInputDuringRuntimeClipboardRead(
            estimatedBytes: text.utf8.count,
            replay: { [weak self] in
                _ = self?.sendInputAfterExplicitInput(text)
            }
        ) {
            return .queued
        }
        guard surface != nil else {
            guard allowsRuntimeSurfaceCreation() else { return .surfaceUnavailable }
            let queued = enqueuePendingSocketInput(text)
            if queued {
                requestInputDemandSurfaceStartIfNeeded()
                didAcceptExplicitInput()
            }
            return queued ? .queued : .inputQueueFull
        }
        return sendInputToLiveSurfaceAfterExplicitInput(text)
    }

    @MainActor
    private func sendInputToLiveSurfaceAfterExplicitInput(
        _ text: String,
        allowClipboardDeferral: Bool = true
    ) -> InputSendResult {
        guard let liveSurface = liveSurfaceForSocketWrite(reason: "socket.sendInput") else {
            return .surfaceUnavailable
        }
        guard !ghostty_surface_process_exited(liveSurface) else { return .processExited }
        var validatedSurface: ghostty_surface_t? = liveSurface
        var validatedGeneration: UInt64? = runtimeSurfaceGeneration
        var queuedInput = false
        for input in Self.pendingSocketInputs(for: text) {
            let wasDeferred = deliverPendingSocketInput(
                input,
                validatedSurface: &validatedSurface,
                validatedGeneration: &validatedGeneration,
                allowClipboardDeferral: allowClipboardDeferral
            )
            // `deliverPendingSocketInput` returns false for an immediate write
            // and for a failed surface lookup. The validated pointer is the
            // only synchronous failure signal available at this seam.
            guard validatedSurface != nil else { return .surfaceUnavailable }
            queuedInput = wasDeferred || queuedInput
        }
        didAcceptExplicitInput()
        return queuedInput ? .queued : .sent
    }
}
