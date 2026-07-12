#if os(iOS)
import CmuxAgentGUIProjection
import SwiftUI

struct TranscriptSyncStatusView: View {
    let presentation: TranscriptSyncPresentation
    let theme: AgentGUITheme
    let retry: () -> Void
    let showTerminal: () -> Void

    var body: some View {
        switch presentation {
        case .hidden:
            EmptyView()
        case .loading:
            VStack(spacing: 10) {
                ProgressView()
                Text(AgentGUIL10n.string("agent.sync.loading", defaultValue: "Loading conversation…"))
                    .font(.footnote)
            }
            .foregroundStyle(Color(theme.dimForeground))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .error:
            statusCard(
                title: AgentGUIL10n.string("agent.sync.failed.title", defaultValue: "Conversation unavailable"),
                message: AgentGUIL10n.string(
                    "agent.sync.failed.message",
                    defaultValue: "cmux could not update this conversation. Retry or continue in Terminal."
                )
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .stale:
            statusCard(
                title: AgentGUIL10n.string("agent.sync.stale.title", defaultValue: "Showing saved conversation"),
                message: AgentGUIL10n.string(
                    "agent.sync.stale.message",
                    defaultValue: "New activity is not available yet."
                )
            )
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    private func statusCard(title: String, message: String) -> some View {
        VStack(spacing: 8) {
            Text(title).font(.headline)
            Text(message)
                .font(.footnote)
                .foregroundStyle(Color(theme.dimForeground))
                .multilineTextAlignment(.center)
            HStack {
                Button(AgentGUIL10n.string("agent.sync.retry", defaultValue: "Retry"), action: retry)
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("AgentSyncRetry")
                Button(AgentGUIL10n.string("agent.ask.showTerminal", defaultValue: "Show Terminal"), action: showTerminal)
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("AgentSyncShowTerminal")
            }
        }
        .padding(16)
        .background(Color(theme.raisedBackground).opacity(0.96), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color(theme.border), lineWidth: 1))
        .padding(18)
    }
}
#endif
