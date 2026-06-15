import CmuxMobileSupport
import SwiftUI

#if os(iOS)
struct WorkspaceTerminalEmptyStateView: View {
    let createTerminal: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "terminal")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(TerminalPalette.foreground.opacity(0.6))
                .accessibilityHidden(true)

            VStack(spacing: 4) {
                Text(L10n.string(
                    "mobile.terminal.empty.title",
                    defaultValue: "No terminals in this workspace"
                ))
                .font(.headline)
                .foregroundStyle(TerminalPalette.foreground)

                Text(L10n.string(
                    "mobile.terminal.empty.message",
                    defaultValue: "Create a terminal to start sending commands from your phone."
                ))
                .font(.subheadline)
                .foregroundStyle(TerminalPalette.foreground.opacity(0.68))
            }
            .multilineTextAlignment(.center)

            Button(action: createTerminal) {
                Label(L10n.string("mobile.terminal.new", defaultValue: "New Terminal"), systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .accessibilityIdentifier("MobileTerminalEmptyCreateButton")
        }
        .padding(24)
        .frame(maxWidth: 320)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("MobileTerminalEmptyState")
    }
}
#endif
