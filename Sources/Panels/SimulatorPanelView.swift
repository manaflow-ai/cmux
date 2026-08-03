import AppKit
import CmuxSimulatorUI

@MainActor
final class SimulatorPanelLifecycleHost {
    private let visibilityHostID = UUID()
    private let focusOwnershipView = SimulatorFocusOwnershipView()
    private weak var panel: SimulatorPanel?

    func installFocusOwnershipView(in controller: SimulatorPaneView) {
        _ = controller.view
        guard focusOwnershipView.superview == nil else { return }
        focusOwnershipView.translatesAutoresizingMaskIntoConstraints = false
        controller.view.addSubview(focusOwnershipView)
        NSLayoutConstraint.activate([
            focusOwnershipView.leadingAnchor.constraint(equalTo: controller.view.leadingAnchor),
            focusOwnershipView.trailingAnchor.constraint(equalTo: controller.view.trailingAnchor),
            focusOwnershipView.topAnchor.constraint(equalTo: controller.view.topAnchor),
            focusOwnershipView.bottomAnchor.constraint(equalTo: controller.view.bottomAnchor),
        ])
    }

    func update(
        controller: SimulatorPaneView,
        panel: SimulatorPanel,
        isFocused: Bool,
        isVisibleInUI: Bool,
        allowsPointerInput: Bool,
        pointerEntryEventFilter: (@MainActor (NSEvent) -> Bool)?,
        backgroundColor: NSColor,
        onRequestPanelFocus: @escaping () -> Void
    ) {
        controller.update(
            backgroundColor: backgroundColor,
            allowsPointerInput: allowsPointerInput,
            pointerEntryEventFilter: pointerEntryEventFilter,
            onRequestPanelFocus: onRequestPanelFocus
        )
        if self.panel !== panel {
            self.panel?.coordinator.releaseInputs()
            self.panel?.setVisibleInUI(false, hostID: visibilityHostID)
            self.panel = panel
        }
        focusOwnershipView.update(panel: panel)
        panel.coordinator.setActive(isFocused)
        if !isVisibleInUI {
            panel.coordinator.releaseInputs()
        }
        panel.setVisibleInUI(isVisibleInUI, hostID: visibilityHostID)
    }

    func teardown(controller: SimulatorPaneView) {
        controller.teardown()
        panel?.coordinator.releaseInputs()
        panel?.setVisibleInUI(false, hostID: visibilityHostID)
        focusOwnershipView.teardown()
        panel = nil
    }
}
