import CmuxSimulator
import SwiftUI

struct SimulatorWebInspectorTools: View {
    let coordinator: SimulatorPaneCoordinator

    var body: some View {
        SimulatorWebInspectorToolsContent(
            isAvailable: coordinator.supports(.webInspector),
            targets: coordinator.webInspectorTargets,
            session: coordinator.webInspectorSession,
            isHighlighted: coordinator.webInspectorIsHighlighted,
            responses: coordinator.webInspectorResponses,
            refresh: { Task { await coordinator.refreshWebInspectorTargets() } },
            attach: { targetID in Task { await coordinator.attachWebInspector(targetID: targetID) } },
            release: { Task { await coordinator.releaseWebInspector() } },
            setHighlight: { enabled in
                Task { await coordinator.setWebInspectorHighlight(enabled: enabled) }
            },
            send: { json in Task { await coordinator.sendWebInspectorMessage(json) } },
            clearResponses: coordinator.clearWebInspectorResponses
        )
        .task(id: coordinator.frameTransport) {
            guard coordinator.frameTransport != nil, coordinator.supports(.webInspector) else { return }
            await coordinator.refreshWebInspectorTargets()
        }
    }
}
