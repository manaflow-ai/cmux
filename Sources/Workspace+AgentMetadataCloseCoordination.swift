import Foundation

extension Workspace {
    @discardableResult
    func deferPanelCloseUntilAgentMetadataCaptured(
        panelId: UUID,
        captureTask: AgentMetadataCapture?
    ) -> Task<Void, Never>? {
        guard let captureTask else { return nil }
        guard let panel = panels[panelId] as? TerminalPanel else { return nil }
        panel.retireFromUIForDeferredClose()
        let coordinatedCaptureTask = Task { @MainActor [panel] in
            await captureTask.processMetadataCaptureTask.value
            panel.teardownRuntimeForClose()
            await captureTask.enrichmentTask.value
        }
        return agentMetadataCloseDeferrer.deferClose(
            id: panelId,
            until: coordinatedCaptureTask
        ) { [panel] in
            panel.close()
        }
    }

    func deferAllPanelClosesUntilAgentMetadataCaptured(
        _ captureTask: AgentMetadataCapture?
    ) {
        guard let captureTask else { return }
        for panelId in panels.keys {
            deferPanelCloseUntilAgentMetadataCaptured(
                panelId: panelId,
                captureTask: captureTask
            )
        }
    }
}
