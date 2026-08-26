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
            refresh: {
                coordinator.scheduleControlAction("web-inspector-refresh") {
                    await $0.refreshWebInspectorTargets()
                }
            },
            attach: { targetID in
                coordinator.scheduleControlAction("web-inspector-session") {
                    await $0.attachWebInspector(targetID: targetID)
                }
            },
            release: {
                coordinator.scheduleControlAction("web-inspector-session") {
                    await $0.releaseWebInspector()
                }
            },
            setHighlight: { enabled in
                coordinator.scheduleControlAction("web-inspector-highlight") {
                    await $0.setWebInspectorHighlight(enabled: enabled)
                }
            },
            send: { json in
                coordinator.scheduleControlAction("web-inspector-send") {
                    await $0.sendWebInspectorMessage(json)
                }
            },
            clearResponses: coordinator.clearWebInspectorResponses
        )
        .task(id: coordinator.frameTransport) {
            guard coordinator.frameTransport != nil, coordinator.supports(.webInspector) else { return }
            await coordinator.refreshWebInspectorTargets()
        }
    }
}
