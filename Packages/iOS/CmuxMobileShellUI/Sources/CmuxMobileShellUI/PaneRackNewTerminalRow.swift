import CmuxMobileSupport
import SwiftUI

/// Final unfolded row for creating a terminal in the staged pane.
struct PaneRackNewTerminalRow: View {
    let chromeForeground: Color
    let background: Color
    let create: () -> Void

    var body: some View {
        Button(action: create) {
            Label(
                L10n.string("mobile.terminal.new", defaultValue: "New Terminal"),
                systemImage: "plus"
            )
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(chromeForeground.opacity(0.8))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .padding(.horizontal, 15)
        }
        .buttonStyle(.plain)
        .frame(height: 40)
        .background(background)
        .accessibilityIdentifier("MobileNewTerminalMenuItem")
    }
}
