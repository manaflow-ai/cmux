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
    /// One-time flag for the cross-device teaser; local dogfood resets it
    /// with `defaults delete <bundle> cmux.simulator.phoneControlTeaser.dismissed`.
    @AppStorage("cmux.simulator.phoneControlTeaser.dismissed")
    private var phoneControlTeaserDismissed = false

    var body: some View {
        SimulatorPaneView(
            coordinator: panel.coordinator,
            backgroundColor: Color(nsColor: appearance.contentBackgroundColor),
            allowsPointerInput: allowsPointerInput,
            pointerEntryEventFilter: pointerEntryEventFilter,
            onRequestPanelFocus: onRequestPanelFocus,
            phoneControlTeaser: phoneControlTeaser
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

    /// The one-time "control from iPhone" teaser. `nil` (hidden) once
    /// dismissed or when the pairing flow's feature flag is off, so the chip
    /// can never advertise a dead path. The package renders it only over a
    /// live device stage.
    private var phoneControlTeaser: SimulatorPhoneControlTeaser? {
        guard !phoneControlTeaserDismissed,
              CmuxFeatureFlags.shared.isMobileConnectButtonEnabled else { return nil }
        return SimulatorPhoneControlTeaser(
            openPairing: {
                phoneControlTeaserDismissed = true
                _ = AppDelegate.shared?.performMobileConnectWorkspaceAction(
                    debugSource: "simulator.phoneControlTeaser"
                )
            },
            dismiss: {
                phoneControlTeaserDismissed = true
            }
        )
    }
}
