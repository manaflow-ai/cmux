import CmuxSimulatorUI
import SwiftUI

struct SimulatorPanelView: View {
    let panel: SimulatorPanel
    let isFocused: Bool
    let isVisibleInUI: Bool
    let onRequestPanelFocus: () -> Void

    var body: some View {
        SimulatorPaneView(
            coordinator: panel.coordinator,
            onRequestPanelFocus: onRequestPanelFocus
        )
            .onAppear {
                panel.coordinator.setAccessibilityOverlayVisibility(isVisibleInUI)
                panel.coordinator.setLiveStatusVisibility(isVisibleInUI)
            }
            .onChange(of: isFocused) { _, focused in
                panel.coordinator.setActive(focused)
            }
            .onChange(of: isVisibleInUI) { _, visible in
                if !visible {
                    panel.coordinator.releaseInputs()
                }
                panel.coordinator.setAccessibilityOverlayVisibility(visible)
                panel.coordinator.setLiveStatusVisibility(visible)
            }
            .onDisappear {
                panel.coordinator.releaseInputs()
                panel.coordinator.setAccessibilityOverlayVisibility(false)
                panel.coordinator.setLiveStatusVisibility(false)
            }
    }
}
