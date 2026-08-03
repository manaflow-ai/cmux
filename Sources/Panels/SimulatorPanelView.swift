import AppKit
import CmuxSimulatorUI
import SwiftUI

/// Transitional host for the native AppKit Simulator pane while the parent
/// panel tree is being moved to AppKit.
struct SimulatorPanelView: NSViewControllerRepresentable {
    let panel: SimulatorPanel
    let isFocused: Bool
    let isVisibleInUI: Bool
    let allowsPointerInput: Bool
    let pointerEntryEventFilter: (@MainActor (NSEvent) -> Bool)?
    let appearance: PanelAppearance
    let onRequestPanelFocus: () -> Void

    @MainActor
    final class Coordinator {
        let visibilityHostID = UUID()
        let focusOwnershipView = SimulatorFocusOwnershipView()
        weak var panel: SimulatorPanel?
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSViewController(context: Context) -> SimulatorPaneView {
        let controller = SimulatorPaneView(
            coordinator: panel.coordinator,
            backgroundColor: appearance.contentBackgroundColor,
            allowsPointerInput: allowsPointerInput,
            pointerEntryEventFilter: pointerEntryEventFilter,
            onRequestPanelFocus: onRequestPanelFocus
        )
        _ = controller.view
        let focusView = context.coordinator.focusOwnershipView
        focusView.translatesAutoresizingMaskIntoConstraints = false
        controller.view.addSubview(focusView)
        NSLayoutConstraint.activate([
            focusView.leadingAnchor.constraint(equalTo: controller.view.leadingAnchor),
            focusView.trailingAnchor.constraint(equalTo: controller.view.trailingAnchor),
            focusView.topAnchor.constraint(equalTo: controller.view.topAnchor),
            focusView.bottomAnchor.constraint(equalTo: controller.view.bottomAnchor),
        ])
        focusView.update(panel: panel)
        context.coordinator.panel = panel
        updateLifecycle(context.coordinator)
        return controller
    }

    func updateNSViewController(_ controller: SimulatorPaneView, context: Context) {
        controller.update(
            backgroundColor: appearance.contentBackgroundColor,
            allowsPointerInput: allowsPointerInput,
            pointerEntryEventFilter: pointerEntryEventFilter,
            onRequestPanelFocus: onRequestPanelFocus
        )
        context.coordinator.focusOwnershipView.update(panel: panel)
        context.coordinator.panel = panel
        updateLifecycle(context.coordinator)
    }

    static func dismantleNSViewController(
        _ controller: SimulatorPaneView,
        coordinator: Coordinator
    ) {
        controller.teardown()
        coordinator.panel?.coordinator.releaseInputs()
        coordinator.panel?.setVisibleInUI(false, hostID: coordinator.visibilityHostID)
        coordinator.focusOwnershipView.teardown()
        coordinator.panel = nil
    }

    private func updateLifecycle(_ context: Coordinator) {
        panel.coordinator.setActive(isFocused)
        if !isVisibleInUI { panel.coordinator.releaseInputs() }
        panel.setVisibleInUI(isVisibleInUI, hostID: context.visibilityHostID)
    }
}
