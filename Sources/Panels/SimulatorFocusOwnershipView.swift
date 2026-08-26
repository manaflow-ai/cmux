import AppKit

@MainActor
final class SimulatorFocusOwnershipView: NSView {
    private weak var panel: SimulatorPanel?

    func update(panel: SimulatorPanel) {
        guard self.panel !== panel else {
            panel.setFocusOwnershipView(self)
            return
        }
        self.panel?.clearFocusOwnershipView(self)
        self.panel = panel
        panel.setFocusOwnershipView(self)
    }

    func teardown() {
        panel?.clearFocusOwnershipView(self)
        panel = nil
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}
