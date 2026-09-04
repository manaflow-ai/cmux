public import CMUXMobileCore
import CmuxMobileRPC
public import CmuxMobileShellModel
import Foundation

@MainActor
extension MobileShellComposite {
    /// Serializes start/stop transitions per panel through the composite-owned
    /// operation chain, so a foreground restart cannot overlap a still-running
    /// background stop against the Mac's single-controller ownership.
    public func startMobileSimulatorStream(panelID: String, workspaceID: String) async {
        await enqueueMobileSimulatorStreamOperation(panelID: panelID) { [weak self] in
            await self?.performMobileSimulatorStreamStart(panelID: panelID, workspaceID: workspaceID)
        }.value
    }

    public func stopMobileSimulatorStream(panelID: String, workspaceID: String) async {
        await enqueueMobileSimulatorStreamOperation(panelID: panelID) { [weak self] in
            await self?.performMobileSimulatorStreamStop(panelID: panelID, workspaceID: workspaceID)
        }.value
    }

    /// Stops a still-running v1 image stream for a panel the v2 pane is
    /// taking over (capabilities can arrive after a v1 stream already
    /// started on an older snapshot). Idempotent.
    public func stopLegacySimulatorStream(panelID: String, workspaceID: String) async {
        guard startedMobileSimulatorPanelIDs.contains(panelID) else { return }
        await stopMobileSimulatorStream(panelID: panelID, workspaceID: workspaceID)
    }

    /// Resolves an aggregate workspace row identity before stopping its
    /// Mac-local simulator stream. Navigation owns row IDs, while stream state
    /// and RPC calls remain keyed by the remote workspace identity.
    public func stopActiveMobileSimulatorStream(in workspaceID: MobileWorkspacePreview.ID) {
        stopActiveMobileSimulatorStream(in: remoteWorkspaceID(for: workspaceID).rawValue)
    }

    /// Ends the selected simulator stream because its workspace route is no
    /// longer visible. Selection and wire teardown share this composite-owned
    /// boundary so child view remounts never imply user navigation intent.
    public func stopActiveMobileSimulatorStream(in workspaceID: String) {
        guard let panelID = simulatorStreamStore?.activeState(in: workspaceID)?.id else { return }
        simulatorStreamStore?.deactivate(in: workspaceID)
        _ = enqueueMobileSimulatorStreamOperation(panelID: panelID) { [weak self] in
            await self?.performMobileSimulatorStreamStop(
                panelID: panelID,
                workspaceID: workspaceID
            )
        }
    }

    private func performMobileSimulatorStreamStart(panelID: String, workspaceID: String) async {
        // Simulator streaming v2 runs the panel over its own dedicated lane,
        // owned entirely by the pane view; starting the v1 image-event stream
        // alongside it would double-stream and contend for input ownership.
        // Guarded here, the single choke point, so stall recovery and
        // reconnect restarts cannot resurrect v1 either.
        guard !supportsSimulatorStreamV2 else { return }
        recordSimulatorStream(
            panelID: panelID,
            state: .startRequested,
            ownership: currentSimulatorOwnership(panelID: panelID)
        )
        guard !startedMobileSimulatorPanelIDs.contains(panelID) else {
            armSimulatorStreamStalenessWatchdog(panelID: panelID)
            recordSimulatorStream(
                panelID: panelID,
                state: .started,
                ownership: currentSimulatorOwnership(panelID: panelID)
            )
            return
        }
        guard connectionState == .connected,
              supportsSimulatorStream,
              let client = remoteClient else {
            settleFailedMobileSimulatorStreamStart(panelID: panelID)
            recordSimulatorStream(
                panelID: panelID,
                state: .startFailed,
                ownership: currentSimulatorOwnership(panelID: panelID)
            )
            return
        }
        simulatorStreamStore?.simulatorStreamWillStart(panelID: panelID)
        do {
            let descriptor = try await client.startMobileSimulatorStream(
                panelID: panelID,
                workspaceID: workspaceID
            )
            guard connectionState == .connected,
                  remoteClient === client else {
                settleFailedMobileSimulatorStreamStart(panelID: panelID)
                recordSimulatorStream(
                    panelID: panelID,
                    state: .startFailed,
                    ownership: currentSimulatorOwnership(panelID: panelID)
                )
                return
            }
            startedMobileSimulatorPanelIDs.insert(panelID)
            simulatorStreamStore?.simulatorStreamDidStart(descriptor)
            armSimulatorStreamStalenessWatchdog(panelID: panelID)
            recordSimulatorStream(
                panelID: panelID,
                state: .started,
                ownership: currentSimulatorOwnership(panelID: panelID),
                activeSessions: startedMobileSimulatorPanelIDs.count
            )
        } catch MobileShellConnectionError.rpcError(let code, _) where code == "locked" {
            simulatorStreamStore?.state(for: panelID)?.markLockedByOtherConnection()
            recordSimulatorStream(panelID: panelID, state: .locked, ownership: .otherConnection)
        } catch {
            settleFailedMobileSimulatorStreamStart(panelID: panelID)
            recordSimulatorStream(
                panelID: panelID,
                state: .startFailed,
                ownership: currentSimulatorOwnership(panelID: panelID)
            )
        }
    }

    /// Rolls the optimistic `.starting` (set by panel activation and by
    /// `simulatorStreamWillStart`) back to `.idle` when no descriptor was
    /// accepted, so a failed start cannot park the pane on a spinner forever.
    /// Per-panel serialization guarantees at most one start attempt is in
    /// flight, so a stale response can never settle a newer attempt.
    private func settleFailedMobileSimulatorStreamStart(panelID: String) {
        guard let state = simulatorStreamStore?.state(for: panelID),
              state.streamStatus == .starting else { return }
        state.streamStatus = .idle
    }

    private func performMobileSimulatorStreamStop(panelID: String, workspaceID: String) async {
        recordSimulatorStream(
            panelID: panelID,
            state: .stopRequested,
            ownership: currentSimulatorOwnership(panelID: panelID),
            activeSessions: startedMobileSimulatorPanelIDs.count
        )
        startedMobileSimulatorPanelIDs.remove(panelID)
        simulatorStreamStalenessMonitor.disarm(panelID: panelID)
        guard let client = remoteClient else {
            recordSimulatorStream(
                panelID: panelID,
                state: .stopped,
                ownership: currentSimulatorOwnership(panelID: panelID),
                activeSessions: startedMobileSimulatorPanelIDs.count
            )
            return
        }
        do {
            _ = try await client.stopMobileSimulatorStream(
                panelID: panelID,
                workspaceID: workspaceID
            )
            recordSimulatorStream(
                panelID: panelID,
                state: .stopped,
                ownership: currentSimulatorOwnership(panelID: panelID),
                activeSessions: startedMobileSimulatorPanelIDs.count
            )
        } catch {
            recordSimulatorStream(
                panelID: panelID,
                state: .stopFailed,
                ownership: currentSimulatorOwnership(panelID: panelID),
                activeSessions: startedMobileSimulatorPanelIDs.count
            )
        }
    }

    /// Appends one operation to the panel's chain. Each operation awaits its
    /// predecessor, cancellation skips the body without breaking the chain,
    /// and the map entry self-removes once its tail drains.
    private func enqueueMobileSimulatorStreamOperation(
        panelID: String,
        _ operation: @escaping @MainActor () async -> Void
    ) -> Task<Void, Never> {
        let previous = mobileSimulatorStreamOperationsByPanel[panelID]
        let task = Task { @MainActor in
            await previous?.value
            guard !Task.isCancelled else { return }
            await operation()
        }
        mobileSimulatorStreamOperationsByPanel[panelID] = task
        Task { @MainActor [weak self] in
            await task.value
            guard let self, self.mobileSimulatorStreamOperationsByPanel[panelID] == task else { return }
            self.mobileSimulatorStreamOperationsByPanel.removeValue(forKey: panelID)
        }
        return task
    }

    /// Cancels queued (not yet started) operations on disconnect; each chain
    /// entry re-checks connection state before touching the wire anyway. The
    /// staleness watchdogs disarm with them: once disconnected, the connection
    /// layer owns the pane's truth (reconnecting/disconnected overlays).
    func cancelMobileSimulatorStreamOperations() {
        for task in mobileSimulatorStreamOperationsByPanel.values {
            task.cancel()
        }
        mobileSimulatorStreamOperationsByPanel.removeAll()
        simulatorStreamStalenessMonitor.disarmAll()
    }

    /// Arms the per-panel staleness watchdog for an active stream. Gated on
    /// the keepalive capability: without the Mac's fixed-cadence
    /// `simulator.state` emissions, a static Simulator screen would be
    /// indistinguishable from a dead stream and stall falsely.
    private func armSimulatorStreamStalenessWatchdog(panelID: String) {
        guard supportsSimulatorKeepalive else { return }
        simulatorStreamStalenessMonitor.arm(panelID: panelID)
    }

    /// A full staleness threshold passed with no frame or keepalive for an
    /// active stream while the connection still reports connected: surface the
    /// stall instead of letting the last frame masquerade as live, and
    /// re-request the stream through the panel's serialized operation chain.
    /// The watchdog stays armed, so a recovery that dies silently retries on
    /// the next silent interval.
    public func handleStaleMobileSimulatorStream(panelID: String) {
        guard startedMobileSimulatorPanelIDs.contains(panelID) else {
            simulatorStreamStalenessMonitor.disarm(panelID: panelID)
            return
        }
        guard connectionState == .connected else { return }
        guard let state = simulatorStreamStore?.state(for: panelID) else { return }
        state.markStreamStale()
        recordSimulatorStream(
            panelID: panelID,
            state: .stalled,
            ownership: currentSimulatorOwnership(panelID: panelID),
            activeSessions: startedMobileSimulatorPanelIDs.count
        )
        let workspaceID = state.workspaceID
        _ = enqueueMobileSimulatorStreamOperation(panelID: panelID) { [weak self] in
            guard let self else { return }
            // Cleared inside the serialized operation so it cannot race a
            // still-draining stop for the same panel.
            self.startedMobileSimulatorPanelIDs.remove(panelID)
            await self.performMobileSimulatorStreamStart(
                panelID: panelID,
                workspaceID: workspaceID
            )
        }
    }

    /// Clears a decode-level stall after the pane presents a real image.
    public func mobileSimulatorFrameDidPresent(panelID: String) {
        simulatorStreamStore?.simulatorFrameDidPresent(panelID: panelID)
    }

    public func sendMobileSimulatorPointer(_ input: MobileSimulatorPointerInput) async {
        let detail = Self.diagnosticPointerPhase(input.phase).rawValue
        recordSimulatorCoordinate(panelID: input.panelID, x: input.x, y: input.y, mapping: .mapped)
        recordSimulatorInput(panelID: input.panelID, state: .queued, kind: .pointer, detail: detail)
        guard let client = remoteClient else {
            recordSimulatorInput(panelID: input.panelID, state: .unavailable, kind: .pointer, detail: detail)
            return
        }
        recordSimulatorInput(panelID: input.panelID, state: .sent, kind: .pointer, detail: detail)
        do {
            _ = try await client.sendMobileSimulatorPointer(input)
            recordSimulatorInput(panelID: input.panelID, state: .accepted, kind: .pointer, detail: detail)
        } catch MobileShellConnectionError.rpcError(let code, _) where code == "locked" {
            recordSimulatorInput(panelID: input.panelID, state: .rejectedLocked, kind: .pointer, detail: detail)
        } catch {
            recordSimulatorInput(panelID: input.panelID, state: .failed, kind: .pointer, detail: detail)
        }
    }

    public func sendMobileSimulatorText(_ input: MobileSimulatorTextInput) async {
        let detail = input.text.utf8.count
        recordSimulatorInput(panelID: input.panelID, state: .queued, kind: .text, detail: detail)
        guard let client = remoteClient else {
            recordSimulatorInput(panelID: input.panelID, state: .unavailable, kind: .text, detail: detail)
            return
        }
        recordSimulatorInput(panelID: input.panelID, state: .sent, kind: .text, detail: detail)
        do {
            _ = try await client.sendMobileSimulatorText(input)
            recordSimulatorInput(panelID: input.panelID, state: .accepted, kind: .text, detail: detail)
        } catch MobileShellConnectionError.rpcError(let code, _) where code == "locked" {
            recordSimulatorInput(panelID: input.panelID, state: .rejectedLocked, kind: .text, detail: detail)
        } catch {
            recordSimulatorInput(panelID: input.panelID, state: .failed, kind: .text, detail: detail)
        }
    }

    public func sendMobileSimulatorButton(_ input: MobileSimulatorButtonInput) async {
        let detail = Self.diagnosticButtonKind(input.button).rawValue
        recordSimulatorInput(panelID: input.panelID, state: .queued, kind: .hardwareButton, detail: detail)
        guard let client = remoteClient else {
            recordSimulatorInput(panelID: input.panelID, state: .unavailable, kind: .hardwareButton, detail: detail)
            return
        }
        recordSimulatorInput(panelID: input.panelID, state: .sent, kind: .hardwareButton, detail: detail)
        do {
            _ = try await client.sendMobileSimulatorButton(input)
            recordSimulatorInput(panelID: input.panelID, state: .accepted, kind: .hardwareButton, detail: detail)
        } catch MobileShellConnectionError.rpcError(let code, _) where code == "locked" {
            recordSimulatorInput(panelID: input.panelID, state: .rejectedLocked, kind: .hardwareButton, detail: detail)
        } catch {
            recordSimulatorInput(panelID: input.panelID, state: .failed, kind: .hardwareButton, detail: detail)
        }
    }

    func handleMobileSimulatorFrameEvent(_ event: MobileEventEnvelope) {
        guard let payload = event.payloadJSON else { return }
        switch simulatorStreamStore?.receiveSimulatorFramePayload(payload) {
        case .received(let panelID, let sequence, let payloadBytes):
            simulatorStreamStalenessMonitor.recordActivity(panelID: panelID)
            recordSimulatorFrame(panelID: panelID, state: .received, sequence: sequence, payloadBytes: payloadBytes)
        case .stale(let panelID, let sequence, _, let payloadBytes):
            // An out-of-order frame still proves the Mac session is alive.
            simulatorStreamStalenessMonitor.recordActivity(panelID: panelID)
            recordSimulatorFrame(panelID: panelID, state: .staleIgnored, sequence: sequence, payloadBytes: payloadBytes)
        case .decodeFailed(let payloadBytes):
            recordSimulatorFrame(panelID: "", state: .decodeFailed, payloadBytes: payloadBytes)
        case .unknownPanel(let panelID, let sequence, let payloadBytes):
            recordSimulatorFrame(panelID: panelID, state: .unknownPanel, sequence: sequence, payloadBytes: payloadBytes)
        case nil:
            break
        }
    }

    func handleMobileSimulatorStateEvent(_ event: MobileEventEnvelope) {
        guard let payload = event.payloadJSON else { return }
        switch simulatorStreamStore?.receiveSimulatorStatePayload(payload) {
        case .unchanged(let panelID):
            // Keepalive re-emission: feeds the staleness watchdog, records
            // no diagnostic (a healthy session would flood one every 5s).
            simulatorStreamStalenessMonitor.recordActivity(panelID: panelID)
        case .applied(let panelID, let ownership, let previousOwnership):
            simulatorStreamStalenessMonitor.recordActivity(panelID: panelID)
            recordSimulatorStream(panelID: panelID, state: .descriptorApplied, ownership: ownership)
            if previousOwnership != ownership {
                recordSimulatorOwnership(
                    panelID: panelID,
                    ownership: ownership,
                    previousOwnership: previousOwnership
                )
            }
        case .decodeFailed(let payloadBytes):
            recordSimulatorFrame(panelID: "", state: .decodeFailed, payloadBytes: payloadBytes)
        case nil:
            break
        }
    }

    func handleMobileSimulatorClosedEvent(_ event: MobileEventEnvelope) {
        guard let payload = event.payloadJSON else { return }
        if let panelID = simulatorStreamStore?.receiveSimulatorClosedPayload(payload) {
            startedMobileSimulatorPanelIDs.remove(panelID)
            simulatorStreamStalenessMonitor.disarm(panelID: panelID)
            recordSimulatorStream(
                panelID: panelID,
                state: .closed,
                ownership: currentSimulatorOwnership(panelID: panelID),
                activeSessions: startedMobileSimulatorPanelIDs.count
            )
        }
    }

    func restartActiveMobileSimulatorStreams() {
        guard connectionState == .connected, supportsSimulatorStream else { return }
        let selections = simulatorStreamStore?.activeSimulatorStreamSelections() ?? []
        for selection in selections {
            recordSimulatorStream(
                panelID: selection.panelID,
                state: .restartRequested,
                ownership: currentSimulatorOwnership(panelID: selection.panelID)
            )
            _ = enqueueMobileSimulatorStreamOperation(panelID: selection.panelID) { [weak self] in
                guard let self else { return }
                // Cleared inside the serialized operation so it cannot race a
                // still-draining stop for the same panel.
                self.startedMobileSimulatorPanelIDs.remove(selection.panelID)
                await self.performMobileSimulatorStreamStart(
                    panelID: selection.panelID,
                    workspaceID: selection.workspaceID
                )
            }
        }
    }

    func stopActiveMobileSimulatorStreamsForBackground() {
        let selections = simulatorStreamStore?.activeSimulatorStreamSelections() ?? []
        simulatorStreamStore?.pauseSimulatorStreams()
        for selection in selections {
            recordSimulatorStream(
                panelID: selection.panelID,
                state: .pausedForBackground,
                ownership: currentSimulatorOwnership(panelID: selection.panelID)
            )
            _ = enqueueMobileSimulatorStreamOperation(panelID: selection.panelID) { [weak self] in
                await self?.performMobileSimulatorStreamStop(
                    panelID: selection.panelID,
                    workspaceID: selection.workspaceID
                )
            }
        }
    }
}
