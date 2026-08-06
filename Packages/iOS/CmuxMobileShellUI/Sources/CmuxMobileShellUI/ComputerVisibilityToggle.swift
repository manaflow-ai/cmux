#if os(iOS)
import CmuxMobileSupport
import SwiftUI

/// A row-local switch for whether one computer appears on this iPhone.
///
/// The pending value moves immediately with the user's gesture while the
/// durable hide marker updates. If the mutation cannot be applied, the switch
/// returns to the authoritative value supplied by the parent row.
struct ComputerVisibilityToggle: View {
    let computerID: String
    let computerName: String
    let isVisible: Bool
    let setVisible: @MainActor (Bool) async -> Void

    @State private var pendingValue: Bool?
    @State private var actionTask: Task<Void, Never>?

    private var displayedValue: Bool { pendingValue ?? isVisible }

    var body: some View {
        Toggle(
            L10n.string(
                "mobile.computers.visibilityToggle",
                defaultValue: "Show this computer on this iPhone"
            ),
            isOn: Binding(
                get: { displayedValue },
                set: beginMutation
            )
        )
        .labelsHidden()
        .disabled(actionTask != nil)
        .accessibilityLabel(
            String(
                format: L10n.string(
                    "mobile.computers.visibilityToggle.named",
                    defaultValue: "Show %@ on this iPhone"
                ),
                computerName
            )
        )
        .accessibilityIdentifier("MobileComputerVisibilityToggle-\(computerID)")
        .onChange(of: isVisible) { _, newValue in
            guard actionTask == nil else { return }
            pendingValue = newValue
        }
    }

    private func beginMutation(_ newValue: Bool) {
        guard actionTask == nil, newValue != displayedValue else { return }
        pendingValue = newValue
        actionTask = Task { @MainActor in
            await setVisible(newValue)
            pendingValue = nil
            actionTask = nil
        }
    }
}
#endif
