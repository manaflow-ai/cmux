import AppKit
import CmuxSimulatorUI
import SwiftUI

struct SimulatorPanelView: View {
    let panel: SimulatorPanel
    let isFocused: Bool
    let isVisibleInUI: Bool
    let allowsPointerInput: Bool
    let pointerEntryEventFilter: (@MainActor (NSEvent) -> Bool)?
    let appearance: PanelAppearance
    let onRequestPanelFocus: () -> Void
    @State private var visibilityHostID = UUID()

    var body: some View {
        SimulatorPaneView(
            coordinator: panel.coordinator,
            backgroundColor: Color(nsColor: appearance.contentBackgroundColor),
            allowsPointerInput: allowsPointerInput,
            pointerEntryEventFilter: pointerEntryEventFilter,
            onRequestPanelFocus: onRequestPanelFocus
        )
            .background {
                SimulatorFocusOwnershipBridge(panel: panel)
            }
            .environment(
                \.colorScheme,
                cmuxReadableColorScheme(for: appearance.backgroundColor)
            )
            .onAppear {
                panel.coordinator.setActive(isFocused)
                panel.setVisibleInUI(isVisibleInUI, hostID: visibilityHostID)
            }
            .onChange(of: isFocused) { _, focused in
                panel.coordinator.setActive(focused)
            }
            .onChange(of: isVisibleInUI) { _, visible in
                if !visible {
                    panel.coordinator.releaseInputs()
                }
                panel.setVisibleInUI(visible, hostID: visibilityHostID)
            }
            .onDisappear {
                panel.coordinator.releaseInputs()
                panel.setVisibleInUI(false, hostID: visibilityHostID)
            }
    }
}
