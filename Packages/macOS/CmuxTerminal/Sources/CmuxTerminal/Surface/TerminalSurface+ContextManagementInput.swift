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
    /// - Parameter enabled: Whether this surface is eligible for detection.
    @MainActor
    public func setContextPressureMonitoringEnabled(_ enabled: Bool) {
        contextPressureMonitoringEnabled = enabled
        mobileByteTeeLease?.setContextPressureMonitoringEnabled(enabled)
    }

    /// Notifies the pane host that explicit terminal input is about to be sent.
    ///
    /// `isUserInitiated` is reserved for input that originated in an actual
    /// user event. Socket/API callers and cmux-authored recovery writes keep
    /// the legacy pane-host notification without cancelling pending
    /// automation for the same surface.
    ///
    /// - Parameter isUserInitiated: Whether to cancel pending context recovery.
    @MainActor
    public func didReceiveExplicitInput(isUserInitiated: Bool = false) {
        paneHost.terminalSurfaceDidReceiveExplicitInput()
        if isUserInitiated {
            onUserExplicitInput?()
        }
    }

    /// Notifies the current panel owner after explicit terminal input is accepted.
    @MainActor
    public func didAcceptExplicitInput() {
        onExplicitInput?()
    }

    /// Publishes accepted user intent without duplicating the pane-host input
    /// notification already sent by the shared write API.
    @MainActor
    func didAcceptUserInitiatedInput(_ isUserInitiated: Bool, accepted: Bool) {
        if isUserInitiated, accepted {
            onUserExplicitInput?()
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
