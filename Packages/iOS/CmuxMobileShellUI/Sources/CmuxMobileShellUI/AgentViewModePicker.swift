#if os(iOS)
import CmuxMobileSupport
import SwiftUI

/// Switches the same live terminal between its native conversation and TUI.
struct AgentViewModePicker: View {
    let isGUI: Bool
    let selectGUI: (Bool) -> Void

    var body: some View {
        Picker(
            L10n.string("mobile.agent.viewMode", defaultValue: "View mode", bundle: .module),
            selection: Binding(get: { isGUI }, set: selectGUI)
        ) {
            Text(L10n.string("mobile.agent.viewMode.gui", defaultValue: "GUI", bundle: .module))
                .tag(true)
            Text(L10n.string("mobile.agent.viewMode.terminal", defaultValue: "Terminal", bundle: .module))
                .tag(false)
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
        .accessibilityIdentifier("MobileAgentViewModePicker")
    }
}
#endif
