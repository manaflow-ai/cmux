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
    var isDisabled = false
    let setVisible: (Bool) -> Void

    var body: some View {
        Toggle(
            L10n.string(
                "mobile.connections.visibilityToggle",
                defaultValue: "Show this computer on this iPhone"
            ),
            isOn: Binding(
                get: { isVisible },
                set: { newValue, transaction in
                    var animatedTransaction = transaction
                    animatedTransaction.animation = .easeInOut(duration: 0.2)
                    withTransaction(animatedTransaction) {
                        setVisible(newValue)
                    }
                }
            )
        )
        .labelsHidden()
        .accessibilityLabel(
            L10n.string(
                "mobile.computers.visibilityToggle.named",
                defaultValue: "Show \(computerName) on this iPhone"
            )
        )
        .accessibilityIdentifier("MobileComputerVisibilityToggle-\(computerID)")
        .animation(.easeInOut(duration: 0.2), value: isVisible)
        .disabled(isDisabled)
    }
}
#endif
