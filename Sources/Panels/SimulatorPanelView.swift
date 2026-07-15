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

    var body: some View {
        SimulatorPaneView(
            coordinator: panel.coordinator,
            backgroundColor: Color(nsColor: appearance.contentBackgroundColor),
            allowsPointerInput: allowsPointerInput,
            pointerEntryEventFilter: pointerEntryEventFilter,
            onRequestPanelFocus: onRequestPanelFocus
        )
            .environment(
                \.colorScheme,
                cmuxReadableColorScheme(for: appearance.backgroundColor)
            )
            .onAppear {
                panel.resumeAfterRemoteEnable()
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

struct SimulatorFeatureDisabledView: View {
    let panel: SimulatorPanel
    let appearance: PanelAppearance

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "iphone.slash")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text(String(
                localized: "simulator.featureDisabled.title",
                defaultValue: "Simulator is temporarily unavailable"
            ))
            .font(.headline)
            Text(String(
                localized: "simulator.featureDisabled.message",
                defaultValue: "This feature has been disabled remotely."
            ))
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: appearance.contentBackgroundColor))
        .environment(
            \.colorScheme,
            cmuxReadableColorScheme(for: appearance.backgroundColor)
        )
        .onAppear {
            // A remote kill switch must release the isolated worker and every
            // long-running Simulator resource. Re-enabling replaces this closed
            // coordinator with a fresh isolated client for the same device.
            panel.suspendForRemoteDisable()
        }
    }
}
