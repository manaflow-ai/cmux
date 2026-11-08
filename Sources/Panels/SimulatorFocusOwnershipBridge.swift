import SwiftUI

struct SimulatorFocusOwnershipBridge: NSViewRepresentable {
    let panel: SimulatorPanel

    func makeNSView(context: Context) -> SimulatorFocusOwnershipView {
        let view = SimulatorFocusOwnershipView()
        view.update(panel: panel)
        return view
    }

    func updateNSView(_ view: SimulatorFocusOwnershipView, context: Context) {
        view.update(panel: panel)
    }

    static func dismantleNSView(
        _ view: SimulatorFocusOwnershipView,
        coordinator: Void
    ) {
        view.teardown()
    }
}
