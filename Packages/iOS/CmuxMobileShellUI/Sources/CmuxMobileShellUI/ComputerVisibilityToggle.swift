#if os(iOS)
import CmuxMobileSupport
import SwiftUI

/// A row-local switch for whether one computer appears on this iPhone.
///
/// The owning row performs the asynchronous mutation. This leaf view only
/// reports the requested value and renders the authoritative row state.
struct ComputerVisibilityToggle: View {
    let computerID: String
    let computerName: String
    let isVisible: Bool
    let setVisible: (Bool) -> Void

    var body: some View {
        Toggle(
            L10n.string(
                "mobile.computers.visibilityToggle",
                defaultValue: "Show this computer on this iPhone"
            ),
            isOn: Binding(
                get: { isVisible },
                set: { newValue in setVisible(newValue) }
            )
        )
        .labelsHidden()
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
    }
}
#endif
