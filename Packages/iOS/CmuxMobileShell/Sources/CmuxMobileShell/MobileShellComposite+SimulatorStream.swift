public import CMUXMobileCore
import CmuxMobileRPC
import Foundation

@MainActor
extension MobileShellComposite {
    public func startMobileSimulatorStream(panelID: String, workspaceID: String) async {
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
                  remoteClient === client else { return }
            startedMobileSimulatorPanelIDs.insert(panelID)
            simulatorStreamStore?.simulatorStreamDidStart(descriptor)
        } catch MobileShellConnectionError.rpcError(let code, _) where code == "locked" {
            simulatorStreamStore?.state(for: panelID)?.streamStatus = .locked
        } catch {}
    }

    public func stopMobileSimulatorStream(panelID: String, workspaceID: String) async {
        startedMobileSimulatorPanelIDs.remove(panelID)
        guard let client = remoteClient else { return }
        _ = try? await client.stopMobileSimulatorStream(panelID: panelID, workspaceID: workspaceID)
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
            startedMobileSimulatorPanelIDs.remove(selection.panelID)
            Task {
                await startMobileSimulatorStream(
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
            Task {
                await stopMobileSimulatorStream(
                    panelID: selection.panelID,
                    workspaceID: selection.workspaceID
                )
            }
        }
    }
}
