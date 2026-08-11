import CMUXMobileCore
import CmuxMobileSupport
import SwiftUI

/// One-tap workspace-chrome control for discovering an interactive Mac Simulator panel.
struct SimulatorPickerControl: View {
    let value: SimulatorPickerMenuValue
    let toggle: () -> Void
    let terminalTheme: TerminalTheme

    var body: some View {
        Button {
            toggle()
        } label: {
            Label(
                L10n.string("mobile.simulatorStream.menuTitle", defaultValue: "Mac Simulators"),
                systemImage: value.activePanelID == nil ? "iphone" : "iphone.circle.fill"
            )
            .labelStyle(.iconOnly)
        }
        .frame(minWidth: 44, minHeight: 44)
        .contentShape(Rectangle())
        .foregroundStyle(terminalTheme.terminalChromeForegroundColor)
        .accessibilityLabel(
            L10n.string("mobile.simulatorStream.menuTitle", defaultValue: "Mac Simulators")
        )
        .accessibilityIdentifier("MobileSimulatorPicker")
        .accessibilityValue(
            value.rows.first(where: { $0.id == value.activePanelID })?.label ?? ""
        )
        .disabled(value.rows.isEmpty)
    }
}
