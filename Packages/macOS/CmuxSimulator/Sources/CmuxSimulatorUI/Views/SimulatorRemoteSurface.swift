import CmuxSimulator
import SwiftUI

struct SimulatorRemoteSurface: NSViewRepresentable {
    let coordinator: SimulatorPaneCoordinator
    let contextID: UInt32
    let display: SimulatorDisplayMetadata
    let chrome: SimulatorDeviceChromeProfile?
    let onRequestPanelFocus: @MainActor () -> Void

    func makeNSView(context: Context) -> SimulatorRemoteSurfaceView {
        let view = SimulatorRemoteSurfaceView()
        view.simulatorOwnerID = ObjectIdentifier(coordinator)
        view.onMessage = { [weak coordinator] message in
            coordinator?.enqueue(message)
        }
        view.onGeometry = { [weak coordinator] geometry in
            coordinator?.updateGeometry(geometry)
        }
        view.onRequestPanelFocus = onRequestPanelFocus
        view.update(contextID: contextID, display: display, chrome: chrome)
        view.requestFocus(generation: coordinator.focusRequestGeneration)
        return view
    }

    func updateNSView(_ view: SimulatorRemoteSurfaceView, context: Context) {
        view.simulatorOwnerID = ObjectIdentifier(coordinator)
        view.onMessage = { [weak coordinator] message in
            coordinator?.enqueue(message)
        }
        view.onGeometry = { [weak coordinator] geometry in
            coordinator?.updateGeometry(geometry)
        }
        view.onRequestPanelFocus = onRequestPanelFocus
        view.update(contextID: contextID, display: display, chrome: chrome)
        view.requestFocus(generation: coordinator.focusRequestGeneration)
    }

    static func dismantleNSView(_ view: SimulatorRemoteSurfaceView, coordinator: ()) {
        view.teardown()
    }

}
