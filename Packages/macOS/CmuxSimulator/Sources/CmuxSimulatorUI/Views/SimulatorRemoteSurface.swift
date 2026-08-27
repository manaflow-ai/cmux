import AppKit
import CmuxSimulator
import SwiftUI

struct SimulatorRemoteSurface: NSViewRepresentable {
    let coordinator: SimulatorPaneCoordinator
    let frameTransport: SimulatorFrameTransportDescriptor
    let display: SimulatorDisplayMetadata
    let chrome: SimulatorDeviceChromeProfile?
    let allowsPointerInput: Bool
    let pointerEntryEventFilter: (@MainActor (NSEvent) -> Bool)?
    let onRequestPanelFocus: @MainActor () -> Void

    func makeCoordinator() -> SimulatorRemoteSurfaceLifetime {
        SimulatorRemoteSurfaceLifetime()
    }

    func makeNSView(context: Context) -> SimulatorRemoteSurfaceView {
        let view = SimulatorRemoteSurfaceView()
        context.coordinator.view = view
        view.setPointerInputEnabled(allowsPointerInput)
        view.pointerEntryEventFilter = pointerEntryEventFilter
        view.simulatorOwnerID = ObjectIdentifier(coordinator)
        view.onMessage = { [weak coordinator] message in
            coordinator?.enqueue(message)
        }
        view.onGeometry = { [weak coordinator] geometry in
            coordinator?.updateGeometry(geometry)
        }
        view.onRequestPanelFocus = onRequestPanelFocus
        view.onFrameTransportFailure = { [weak coordinator] descriptor, failure in
            Task { @MainActor in
                coordinator?.receiveFrameTransportFailure(failure, for: descriptor)
            }
        }
        view.onFrameTransportAdopted = { [weak coordinator] descriptor in
            coordinator?.acknowledgeFrameTransportAdoption(descriptor)
        }
        view.update(frameTransport: frameTransport, display: display, chrome: chrome)
        view.requestFocus(generation: coordinator.focusRequestGeneration)
        return view
    }

    func updateNSView(_ view: SimulatorRemoteSurfaceView, context: Context) {
        context.coordinator.view = view
        view.setPointerInputEnabled(allowsPointerInput)
        view.pointerEntryEventFilter = pointerEntryEventFilter
        view.simulatorOwnerID = ObjectIdentifier(coordinator)
        view.onMessage = { [weak coordinator] message in
            coordinator?.enqueue(message)
        }
        view.onGeometry = { [weak coordinator] geometry in
            coordinator?.updateGeometry(geometry)
        }
        view.onRequestPanelFocus = onRequestPanelFocus
        view.onFrameTransportFailure = { [weak coordinator] descriptor, failure in
            Task { @MainActor in
                coordinator?.receiveFrameTransportFailure(failure, for: descriptor)
            }
        }
        view.onFrameTransportAdopted = { [weak coordinator] descriptor in
            coordinator?.acknowledgeFrameTransportAdoption(descriptor)
        }
        view.update(frameTransport: frameTransport, display: display, chrome: chrome)
        view.requestFocus(generation: coordinator.focusRequestGeneration)
    }

}
