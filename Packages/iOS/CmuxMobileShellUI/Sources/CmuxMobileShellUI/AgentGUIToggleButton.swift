#if os(iOS)
import CMUXMobileCore
import CmuxMobileSupport
import SwiftUI

struct AgentGUIToggleButton: View {
    @Binding var isSelected: Bool
    let terminalTheme: TerminalTheme

    private var title: String {
        isSelected
            ? L10n.string("mobile.agentGUI.showTerminal", defaultValue: "Show Terminal")
            : L10n.string("mobile.agentGUI.showTranscript", defaultValue: "Show Agent Transcript")
    }

    var body: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                isSelected.toggle()
            }
        } label: {
            Label(
                title,
                systemImage: isSelected ? "terminal" : "bubble.left.and.text.bubble.right"
            )
            .labelStyle(.iconOnly)
        }
        .foregroundStyle(terminalTheme.terminalChromeForegroundColor)
        .accessibilityLabel(title)
        .accessibilityIdentifier("MobileAgentGUIToggle")
    }
}
#endif
