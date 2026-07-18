extension TerminalSurface {
    /// The runtime's coherent cached state, or nil for embedded Ghostty.
    @MainActor
    public var externalRuntimeSnapshot: TerminalExternalRuntimeSnapshot? {
        externalRuntime?.snapshot
    }

    /// Detaches this app presentation while preserving the canonical terminal.
    ///
    /// App-termination code must use this instead of ``teardownSurface()``.
    /// The lease is idempotent, so a later deinit remains safe.
    @MainActor
    public func detachExternalPresentationPreservingCanonicalTerminal() {
        guard externalRuntime != nil else { return }
        externalCanonicalCloseSuppressedForAppTermination = true
        externalPresentationLease?.detach()
        externalPresentationLease = nil
    }

    /// Sends a semantic physical-key event through the external FIFO ingress.
    ///
    /// The AppKit view uses this path instead of calling `ghostty_surface_key`
    /// when ``isExternallyManaged`` is true.
    @discardableResult
    @MainActor
    public func sendExternalKeyEvent(
        _ event: TerminalExternalKeyEvent
    ) -> TerminalExternalIngressResult {
        guard let externalRuntime else { return .rejected(.unsupported) }
        guard event.key != 0 else { return .rejected(.unsupported) }
        didReceiveExplicitInput()
        hibernationRecorder.recordTerminalInput(workspaceId: tabId, panelId: id)
        return externalRuntime.enqueue(.input(.key(event)))
    }

    /// Updates visual IME marked text without committing bytes to the PTY.
    @discardableResult
    @MainActor
    public func setExternalPreedit(_ text: String?) -> TerminalExternalIngressResult {
        guard let externalRuntime else { return .rejected(.unsupported) }
        return externalRuntime.enqueue(.preedit(
            text.flatMap { $0.isEmpty ? nil : .collapsedAtEnd($0) }
        ))
    }

    /// Updates rich AppKit IME state without committing bytes to the PTY.
    @discardableResult
    @MainActor
    public func setExternalPreeditState(
        _ preedit: TerminalExternalPreedit?
    ) -> TerminalExternalIngressResult {
        guard let externalRuntime else { return .rejected(.unsupported) }
        return externalRuntime.enqueue(.preedit(
            preedit.flatMap { $0.text.isEmpty ? nil : $0 }
        ))
    }

    /// Routes a pointer event through the backend's canonical mouse encoder.
    @discardableResult
    @MainActor
    public func sendExternalMouseEvent(
        _ event: TerminalExternalMouseEvent
    ) -> TerminalExternalIngressResult {
        guard let externalRuntime else { return .rejected(.unsupported) }
        return externalRuntime.enqueue(.mouse(event))
    }

    /// Refreshes the canonical selection asynchronously for clipboard reads.
    @MainActor
    public func readExternalSelection() async -> TerminalExternalSelection? {
        guard let externalRuntime else { return nil }
        return await externalRuntime.readSelection()
    }

    /// Starts bounded, demand-driven semantic reads for AppKit accessibility.
    @MainActor
    public func enableExternalAccessibility() {
        externalRuntime?.enableAccessibility()
    }

    /// Streams revision changes for the daemon-owned accessibility projection.
    @MainActor
    public func externalAccessibilitySnapshots() -> AsyncStream<TerminalAccessibilitySnapshot> {
        externalRuntime?.accessibilitySnapshots() ?? AsyncStream { $0.finish() }
    }

    /// Revalidates a projected OSC 8 link at the daemon revision fence.
    @MainActor
    public func activateExternalAccessibilityLink(
        _ link: TerminalAccessibilityLink,
        snapshot: TerminalAccessibilitySnapshot
    ) async -> String? {
        guard let externalRuntime else { return nil }
        return await externalRuntime.activateAccessibilityLink(link, snapshot: snapshot)
    }

    /// Resolves a command-click through the daemon's canonical OSC 8 state.
    @MainActor
    public func activateExternalHyperlink(
        at event: TerminalExternalMouseEvent
    ) async -> TerminalExternalHyperlinkHit? {
        guard let externalRuntime else { return nil }
        return await externalRuntime.activateHyperlink(at: event)
    }

    @discardableResult
    @MainActor
    public func mutateExternalSelection(
        _ operation: TerminalExternalSelectionOperation
    ) -> TerminalExternalIngressResult {
        guard let externalRuntime else { return .rejected(.unsupported) }
        return externalRuntime.enqueue(.selection(operation))
    }

    @discardableResult
    @MainActor
    public func mutateExternalCopyMode(
        operation: TerminalExternalCopyModeOperation,
        adjustment: TerminalExternalCopyModeAdjustment? = nil,
        count: UInt32 = 1
    ) -> TerminalExternalIngressResult {
        guard let externalRuntime else { return .rejected(.unsupported) }
        return externalRuntime.enqueue(
            .copyMode(operation: operation, adjustment: adjustment, count: count)
        )
    }

    @discardableResult
    @MainActor
    public func scrollExternalTerminal(
        operation: TerminalExternalScrollOperation,
        amount: Int64? = nil
    ) -> TerminalExternalIngressResult {
        guard let externalRuntime else { return .rejected(.unsupported) }
        return externalRuntime.enqueue(.scroll(operation: operation, amount: amount))
    }

    @MainActor
    func enqueueExternalInput(_ input: TerminalExternalInput) -> TerminalExternalIngressResult? {
        guard let externalRuntime else { return nil }
        hibernationRecorder.recordTerminalInput(workspaceId: tabId, panelId: id)
        return externalRuntime.enqueue(.input(input))
    }

    func inputSendResult(from result: TerminalExternalIngressResult) -> InputSendResult {
        switch result {
        case .accepted:
            return .queued
        case .rejected(.queueFull):
            return .inputQueueFull
        case .rejected(.processExited):
            return .processExited
        case .rejected(.unavailable), .rejected(.unsupported):
            return .surfaceUnavailable
        }
    }

    func namedKeySendResult(from result: TerminalExternalIngressResult) -> NamedKeySendResult {
        switch result {
        case .accepted:
            return .queued
        case .rejected(.queueFull):
            return .inputQueueFull
        case .rejected(.processExited):
            return .processExited
        case .rejected(.unavailable), .rejected(.unsupported):
            return .surfaceUnavailable
        }
    }

    @MainActor
    func externalViewport(
        width: Double,
        height: Double,
        xScale: Double,
        yScale: Double,
        backingWidth: Double,
        backingHeight: Double
    ) -> TerminalExternalViewport? {
        let widthPixels = Int(pixelDimension(from: backingWidth))
        let heightPixels = Int(pixelDimension(from: backingHeight))
        guard widthPixels > 0, heightPixels > 0 else { return nil }

        let metrics = externalRuntime?.snapshot.cellMetrics
        let proposedColumns: Int?
        let proposedRows: Int?
        if let metrics, metrics.cellWidthPixels > 0, metrics.cellHeightPixels > 0 {
            let horizontalPadding = max(
                0,
                metrics.surfaceWidthPixels - metrics.columns * metrics.cellWidthPixels
            )
            let verticalPadding = max(
                0,
                metrics.surfaceHeightPixels - metrics.rows * metrics.cellHeightPixels
            )
            proposedColumns = max(1, (widthPixels - horizontalPadding) / metrics.cellWidthPixels)
            proposedRows = max(1, (heightPixels - verticalPadding) / metrics.cellHeightPixels)
        } else {
            proposedColumns = nil
            proposedRows = nil
        }

        return TerminalExternalViewport(
            widthPoints: width,
            heightPoints: height,
            widthPixels: widthPixels,
            heightPixels: heightPixels,
            xScale: xScale,
            yScale: yScale,
            proposedColumns: proposedColumns,
            proposedRows: proposedRows
        )
    }
}
