import AppKit
import SwiftUI

struct SimulatorHostWindowVisibilityObserver: NSViewRepresentable {
    let onVisibilityChanged: @MainActor (UUID, Bool) -> Void
    let onRemoval: @MainActor (UUID) -> Void

    func makeCoordinator() -> SimulatorHostWindowVisibilityCoordinator {
        SimulatorHostWindowVisibilityCoordinator()
    }

    func makeNSView(context: Context) -> SimulatorHostWindowVisibilityView {
        let view = SimulatorHostWindowVisibilityView()
        installHandlers(on: view, coordinator: context.coordinator)
        return view
    }

    func updateNSView(_ view: SimulatorHostWindowVisibilityView, context: Context) {
        installHandlers(on: view, coordinator: context.coordinator)
    }

    static func dismantleNSView(
        _ view: SimulatorHostWindowVisibilityView,
        coordinator: SimulatorHostWindowVisibilityCoordinator
    ) {
        view.teardown()
        coordinator.remove()
    }

    private func installHandlers(
        on view: SimulatorHostWindowVisibilityView,
        coordinator: SimulatorHostWindowVisibilityCoordinator
    ) {
        let observerID = coordinator.observerID
        coordinator.onRemoval = onRemoval
        view.setVisibilityHandler { isVisible in
            onVisibilityChanged(observerID, isVisible)
        }
    }
}
