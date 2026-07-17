import CmuxMobileSupport
import SwiftUI

/// The workspace list's bottom "Ask an agent…" affordance: a glass capsule
/// that opens the full-screen agent-launch composer. Reads as an input field
/// so the home screen itself invites composing a task.
struct AgentLaunchComposeBar: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "sparkles")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Text(L10n.string("mobile.agentLaunch.bar.placeholder", defaultValue: "Ask an agent…"))
                    .font(.body)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(Color.accentColor)
            }
            .padding(.leading, 16)
            .padding(.trailing, 8)
            .frame(height: 48)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .mobileGlassPill()
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 8)
        .accessibilityLabel(L10n.string("mobile.agentLaunch.title", defaultValue: "New Agent Task"))
        .accessibilityIdentifier("MobileAgentLaunchBar")
    }
}
