public import CMUXMobileCore
import CmuxMobileRPC
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

    private func performMobileSimulatorStreamStart(panelID: String, workspaceID: String) async {
        guard !startedMobileSimulatorPanelIDs.contains(panelID),
              connectionState == .connected,
              supportsSimulatorStream,
              let client = remoteClient else { return }
        simulatorStreamStore?.simulatorStreamWillStart(panelID: panelID)
        do {
            let descriptor = try await client.startMobileSimulatorStream(
                panelID: panelID,
                workspaceID: workspaceID
            )
            guard connectionState == .connected,
                  remoteClient === client else {
                settleFailedMobileSimulatorStreamStart(panelID: panelID)
                return
            }
            startedMobileSimulatorPanelIDs.insert(panelID)
            simulatorStreamStore?.simulatorStreamDidStart(descriptor)
        } catch MobileShellConnectionError.rpcError(let code, _) where code == "locked" {
            simulatorStreamStore?.state(for: panelID)?.streamStatus = .locked
        } catch {
            settleFailedMobileSimulatorStreamStart(panelID: panelID)
        }
    }

    /// Rolls the optimistic `.starting` from `simulatorStreamWillStart` back
    /// to `.idle` when no descriptor was accepted, so a failed start cannot
    /// park the pane on a spinner forever. Per-panel serialization guarantees
    /// at most one start attempt is in flight, so a stale response can never
    /// settle a newer attempt.
    private func settleFailedMobileSimulatorStreamStart(panelID: String) {
        guard let state = simulatorStreamStore?.state(for: panelID),
              state.streamStatus == .starting else { return }
        state.streamStatus = .idle
    }

    private func performMobileSimulatorStreamStop(panelID: String, workspaceID: String) async {
        startedMobileSimulatorPanelIDs.remove(panelID)
        guard let client = remoteClient else { return }
        _ = try? await client.stopMobileSimulatorStream(panelID: panelID, workspaceID: workspaceID)
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
    /// entry re-checks connection state before touching the wire anyway.
    func cancelMobileSimulatorStreamOperations() {
        for task in mobileSimulatorStreamOperationsByPanel.values {
            task.cancel()
        }
        mobileSimulatorStreamOperationsByPanel.removeAll()
    }

    public func sendMobileSimulatorPointer(_ input: MobileSimulatorPointerInput) async {
        _ = try? await remoteClient?.sendMobileSimulatorPointer(input)
    }

    public func sendMobileSimulatorText(_ input: MobileSimulatorTextInput) async {
        _ = try? await remoteClient?.sendMobileSimulatorText(input)
    }

    public func sendMobileSimulatorButton(_ input: MobileSimulatorButtonInput) async {
        _ = try? await remoteClient?.sendMobileSimulatorButton(input)
    }

    func handleMobileSimulatorFrameEvent(_ event: MobileEventEnvelope) {
        guard let payload = event.payloadJSON else { return }
        simulatorStreamStore?.receiveSimulatorFramePayload(payload)
    }

    func handleMobileSimulatorStateEvent(_ event: MobileEventEnvelope) {
        guard let payload = event.payloadJSON else { return }
        simulatorStreamStore?.receiveSimulatorStatePayload(payload)
    }

    func handleMobileSimulatorClosedEvent(_ event: MobileEventEnvelope) {
        guard let payload = event.payloadJSON else { return }
        if let panelID = simulatorStreamStore?.receiveSimulatorClosedPayload(payload) {
            startedMobileSimulatorPanelIDs.remove(panelID)
        }
    }

    func restartActiveMobileSimulatorStreams() {
        guard connectionState == .connected, supportsSimulatorStream else { return }
        let selections = simulatorStreamStore?.activeSimulatorStreamSelections() ?? []
        for selection in selections {
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
            _ = enqueueMobileSimulatorStreamOperation(panelID: selection.panelID) { [weak self] in
                await self?.performMobileSimulatorStreamStop(
                    panelID: selection.panelID,
                    workspaceID: selection.workspaceID
                )
            }
        }
    }
}
