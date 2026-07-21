#if os(iOS)
import CmuxAgentChatUI
import CmuxAgentGUIProjection
import CmuxAgentReplica
import SwiftUI

struct AgentTranscriptRowView: View {
    let row: AgentTranscriptRenderRow
    let theme: AgentGUITheme
    let density: TranscriptDensity
    let onOpenAsk: (PendingAsk) -> Void
    let onOpenActivity: (TranscriptActivityDetails) -> Void
    let onOpenFailedTicket: (SendTicket) -> Void
    let onRetrySync: () -> Void
    let onShowTerminal: () -> Void
    let onShowCodeBlock: (String, Int) -> Void

    var body: some View {
        switch row.content {
        case .message(let snapshot):
            ChatMessageRowView(
                snapshot: snapshot,
                actions: ChatRowActions(
                    openTerminal: onShowTerminal,
                    showCodeBlockDetail: onShowCodeBlock
                )
            )
        case .activity(let details):
            AgentActivitySummaryRow(
                details: details,
                theme: theme,
                density: density,
                onOpen: { onOpenActivity(details) }
            )
        case .ask(let ask):
            AgentAskSummaryRow(ask: ask, theme: theme, onOpen: { onOpenAsk(ask) })
        case .metadata(let text):
            Text(text)
                .font(density.metadataFont)
                .foregroundStyle(Color(theme.faintForeground))
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 20)
                .frame(height: 44)
        case .pendingTicket(let ticket):
            AgentPendingTicketRow(
                ticket: ticket,
                theme: theme,
                onOpenFailure: { onOpenFailedTicket(ticket) }
            )
        case .empty(let presentation):
            AgentTranscriptEmptyState(
                presentation: presentation,
                theme: theme,
                onRetry: onRetrySync,
                onShowTerminal: onShowTerminal
            )
        }
    }
}

struct AgentPendingTicketRow: View {
    let ticket: SendTicket
    let theme: AgentGUITheme
    let onOpenFailure: () -> Void

    private var isFailed: Bool {
        if case .failed = ticket.state { return true }
        return false
    }

    var body: some View {
        Group {
            if isFailed {
                Button(action: onOpenFailure) {
                    content
                }
                .buttonStyle(.plain)
            } else {
                content
            }
        }
        .accessibilityIdentifier("AgentPendingTicket")
    }

    private var content: some View {
        HStack(spacing: 10) {
            if isFailed {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
            } else {
                ProgressView().controlSize(.mini)
            }
            Text(ticket.text)
                .font(.subheadline)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            Text(isFailed
                ? AgentGUIL10n.string("agent.send.failed", defaultValue: "Send failed")
                : AgentGUIL10n.string("agent.send.pending", defaultValue: "Sending"))
                .font(.caption)
                .foregroundStyle(Color(theme.faintForeground))
        }
        .foregroundStyle(Color(theme.foreground))
        .padding(.horizontal, 14)
        .frame(height: 52)
        .background(Color(theme.raisedBackground), in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal, 18)
    }
}

struct AgentAskSummaryRow: View {
    let ask: PendingAsk
    let theme: AgentGUITheme
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 10) {
                Image(systemName: ask.kind == .permission ? "hand.raised.fill" : "questionmark.circle.fill")
                    .foregroundStyle(Color(theme.accent))
                VStack(alignment: .leading, spacing: 2) {
                    Text(ask.kind == .permission
                        ? AgentGUIL10n.string("agent.ask.permission", defaultValue: "Permission needed")
                        : AgentGUIL10n.string("agent.ask.question", defaultValue: "Question"))
                        .font(.caption.weight(.semibold))
                    Text(ask.promptSummary)
                        .font(.subheadline)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color(theme.faintForeground))
            }
            .foregroundStyle(Color(theme.foreground))
            .padding(.horizontal, 14)
            .frame(height: 60)
            .background(Color(theme.hoverBackground).opacity(0.55), in: RoundedRectangle(cornerRadius: 14))
            .padding(.horizontal, 18)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("AgentAskSummary")
        .accessibilityLabel(ask.promptSummary)
    }
}

struct AgentActivitySummaryRow: View {
    let details: TranscriptActivityDetails
    let theme: AgentGUITheme
    let density: TranscriptDensity
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 8) {
                if details.summary.items.contains(where: \.isRunning) {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "checkmark.circle")
                        .foregroundStyle(Color(theme.faintForeground))
                }
                Text(AgentGUIL10n.activitySummary(details.summary))
                    .font(density.metadataFont)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
            }
            .foregroundStyle(Color(theme.faintForeground))
            .padding(.horizontal, 24)
            .frame(height: 44)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("AgentActivitySummary")
    }
}

struct AgentTranscriptEmptyState: View {
    let presentation: TranscriptSyncPresentation
    let theme: AgentGUITheme
    let onRetry: () -> Void
    let onShowTerminal: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            switch presentation {
            case .loading:
                ProgressView()
                Text(AgentGUIL10n.string("agent.sync.loading", defaultValue: "Loading conversation…"))
            case .error:
                Text(AgentGUIL10n.string("agent.sync.failed.title", defaultValue: "Conversation unavailable"))
                    .font(.headline)
                HStack {
                    Button(AgentGUIL10n.string("agent.sync.retry", defaultValue: "Retry"), action: onRetry)
                    Button(AgentGUIL10n.string("agent.ask.showTerminal", defaultValue: "Show Terminal"), action: onShowTerminal)
                }
                .buttonStyle(.bordered)
            case .empty:
                Text(AgentGUIL10n.string("agent.transcript.empty", defaultValue: "No messages yet. Say something."))
            case .hidden, .stale:
                EmptyView()
            }
        }
        .font(.footnote)
        .foregroundStyle(Color(theme.dimForeground))
        .frame(maxWidth: .infinity, minHeight: 240)
        .padding(24)
        .accessibilityIdentifier("AgentTranscriptEmptyState")
    }
}
#endif
