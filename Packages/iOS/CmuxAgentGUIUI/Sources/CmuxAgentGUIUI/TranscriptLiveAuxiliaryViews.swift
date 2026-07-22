import CmuxAgentGUIProjection
import CmuxAgentChatUI
import CmuxAgentReplica
import CmuxAgentSync
import CmuxAgentWire
#if os(iOS)
import SwiftUI
#endif

struct AgentSessionInteractionCapabilities: Equatable {
    let canSteer: Bool
    let canAnswer: Bool

    init(canSteer: Bool, canAnswer: Bool) {
        self.canSteer = canSteer
        self.canAnswer = canAnswer
    }

    init(report: GuiCapabilitiesResult?, tier: DetectionTier?) {
        if let report {
            canSteer = report.steerable
            canAnswer = report.answerable
            return
        }
        canSteer = tier == .wrapped || tier == .hooked
        canAnswer = false
    }
}

/// Keeps the selected host path coupled to the loader that authorizes it
/// when SwiftUI presents the artifact outside the transcript row hierarchy.
struct AgentTranscriptArtifactRoute {
    let path: String
    let loader: ChatArtifactLoader
}

#if os(iOS)
struct AgentCapabilityRequestKey: Hashable {
    let sessionID: AgentSessionID
    let sessionVersion: UInt64
    let isConnected: Bool
}

enum AgentTranscriptSheet: Identifiable {
    case ask(PendingAsk)
    case activity(TranscriptActivityDetails)
    case codeBlock(AgentCodeBlockSelection)
    case failedTicket(SendTicket)
    case artifact(AgentTranscriptArtifactRoute)

    var id: String {
        switch self {
        case .ask(let ask): "ask:\(ask.id)"
        case .activity(let details): "activity:\(details.id.description)"
        case .codeBlock(let selection): selection.id
        case .failedTicket(let ticket): "failed-ticket:\(ticket.id.uuidString)"
        case .artifact(let route): "artifact:\(route.path)"
        }
    }
}

enum AgentHistoryLoadFailure {
    case older
    case newer
    case head
    case tail
}

struct AgentSendFailureSheet: View {
    let ticket: SendTicket
    let theme: AgentGUITheme
    let retry: () -> Void
    let showTerminal: () -> Void

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                Text(ticket.text)
                    .textSelection(.enabled)
                Text(AgentGUIL10n.string(
                    "agent.send.failed.message",
                    defaultValue: "This message was not delivered. Retry it or continue in Terminal."
                ))
                    .font(.footnote)
                    .foregroundStyle(Color(theme.dimForeground))
                Button(AgentGUIL10n.string("agent.send.retry", defaultValue: "Retry message"), action: retry)
                    .buttonStyle(.borderedProminent)
                Button(
                    AgentGUIL10n.string("agent.ask.showTerminal", defaultValue: "Show Terminal"),
                    action: showTerminal
                )
                    .buttonStyle(.bordered)
                Spacer()
            }
            .padding(24)
            .background(Color(theme.background))
            .navigationTitle(AgentGUIL10n.string("agent.send.failed", defaultValue: "Send failed"))
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

struct AgentCodeBlockSelection {
    let id: String
    let code: String
    let language: String?
}

struct AgentSyncInsetBanner: View {
    let presentation: TranscriptSyncPresentation
    let phase: AgentConnectivityPhase
    let historyLoadFailed: Bool
    let theme: AgentGUITheme
    let retrySync: () -> Void
    let retryHistory: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if presentation == .stale || presentation == .error {
                Image(systemName: "wifi.slash")
                Text(presentation == .stale
                    ? AgentGUIL10n.string("agent.sync.stale.title", defaultValue: "Showing saved conversation")
                    : AgentGUIL10n.string("agent.sync.failed.title", defaultValue: "Conversation unavailable"))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Button(AgentGUIL10n.string("agent.sync.retry", defaultValue: "Retry"), action: retrySync)
                    .fontWeight(.semibold)
            } else if historyLoadFailed {
                Image(systemName: "exclamationmark.arrow.triangle.2.circlepath")
                Text(AgentGUIL10n.string(
                    "agent.history.load.failed",
                    defaultValue: "Conversation history could not be loaded"
                ))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Button(AgentGUIL10n.string("agent.sync.retry", defaultValue: "Retry"), action: retryHistory)
                    .fontWeight(.semibold)
            } else if case .updating = phase {
                ProgressView().controlSize(.mini)
                Text(AgentGUIL10n.string("agent.sync.updating", defaultValue: "Updating conversation"))
                    .lineLimit(1)
                Spacer(minLength: 0)
            } else {
                Color.clear
                    .accessibilityHidden(true)
            }
        }
        .font(.caption)
        .foregroundStyle(Color(theme.dimForeground))
        .padding(.horizontal, 14)
        .frame(height: 36)
        .background(Color(theme.raisedBackground))
        .accessibilityIdentifier("AgentSyncInsetBanner")
        .accessibilityHidden(
            presentation != .stale
                && presentation != .error
                && !historyLoadFailed
                && phase != .updating
        )
    }
}
#endif
