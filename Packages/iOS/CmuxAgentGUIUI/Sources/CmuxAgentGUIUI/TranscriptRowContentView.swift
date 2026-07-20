#if os(iOS)
import CmuxAgentGUIProjection
import CmuxAgentReplica
import SwiftUI
import UIKit

struct TranscriptRowContentView: View {
    let row: TranscriptRow
    let spacing: TranscriptRowSpacing
    let theme: AgentGUITheme
    let answeringAskID: String?
    let failedAskID: String?
    let onShowActivity: (TranscriptActivityDetails) -> Void
    let onAnswer: (PendingAsk, Int) -> Void
    let onShowTerminal: () -> Void

    private var register: TranscriptRowSpacingRegister {
        TranscriptRowSpacing.register(for: spacing.density)
    }

    var body: some View {
        switch row.rowKind {
        case .proseAgent(let text, _):
            agentAnswer(text: text)
        case .proseUser(let text, _, _):
            bubble(text: text, alignment: .trailing, style: .user)
        case .status(let code, let detail):
            centered(label: [AgentGUIL10n.statusCode(code), detail].compactMap(\.self).joined(separator: " - "))
        case .dateHeader(let dayKey):
            centered(label: dayKey)
        case .boundary:
            centered(label: AgentGUIL10n.string(
                "agent.transcript.boundary",
                defaultValue: "Earlier history is on your Mac"
            ))
        case .hole(let range):
            centered(label: AgentGUIL10n.hole(
                lowerBound: range.lowerBound.rawValue,
                upperBound: range.upperBound.rawValue
            ))
        case .pendingTicket(let ticket):
            bubble(text: ticket.text, alignment: .trailing, style: .pending)
        case .pendingAsk(let ask):
            pendingAsk(ask)
        case .streaming(let textTail):
            bubble(text: textTail, alignment: .leading, style: .streaming)
                .opacity(0.82)
        case .genericActivity(let activity):
            activityRow(activity)
        case .activitySummary(let summary):
            TranscriptActivitySummaryView(
                summary: summary,
                theme: theme,
                density: spacing.density,
                onOpen: {
                    guard let turnID = row.turnID else { return }
                    onShowActivity(TranscriptActivityDetails(turnID: turnID, summary: summary))
                }
            )
                .padding(.horizontal, 24)
                .padding(.top, spacing.top)
                .padding(.bottom, spacing.bottom)
        case .activityItem(let item):
            TranscriptActivityItemView(item: item, theme: theme, density: spacing.density)
                .padding(.horizontal, 24)
                .padding(.top, spacing.top)
                .padding(.bottom, spacing.bottom)
        case .unsupported(let rawKind, let summary):
            activityRow(TranscriptGenericActivity(kindLabel: rawKind, summary: summary))
        }
    }

    private func bubble(
        text: String,
        alignment: HorizontalAlignment,
        style: BubbleStyle
    ) -> some View {
        HStack(spacing: 0) {
            if alignment == .trailing {
                Spacer(minLength: 42)
            }
            TranscriptSelectableText(
                text: text,
                color: UIColor(style.foreground(theme: theme)),
                usesAvailableWidth: alignment == .leading
            )
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(style.background(theme: theme), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .accessibilityLabel(text)
            if alignment == .leading {
                Spacer(minLength: 42)
            }
        }
        .containerRelativeFrame(.horizontal, alignment: alignment == .trailing ? .trailing : .leading) { length, _ in
            alignment == .trailing ? length * 0.85 : length
        }
        .padding(.horizontal, 24)
        .padding(.top, spacing.top)
        .padding(.bottom, spacing.bottom)
    }

    private func agentAnswer(text: String) -> some View {
        TranscriptSelectableText(
            text: text,
            color: UIColor(theme.foreground),
            usesAvailableWidth: true
        )
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.top, spacing.top)
            .padding(.bottom, spacing.bottom)
            .accessibilityLabel(text)
    }

    private func centered(label: String) -> some View {
        Text(label)
            .font(spacing.density.metadataFont)
            .foregroundStyle(Color(theme.faintForeground))
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 20)
            .padding(.vertical, register.metadataVerticalPadding)
            .padding(.top, spacing.top)
            .padding(.bottom, spacing.bottom)
            .accessibilityLabel(label)
    }

    private func activityRow(_ activity: TranscriptGenericActivity) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol(for: activity.kindLabel))
                .foregroundStyle(Color(theme.faintForeground))
            Text(AgentGUIL10n.activityKind(activity.kindLabel))
                .font(spacing.density.metadataFont.weight(.semibold))
            Text(activity.summary)
                .font(spacing.density.metadataFont)
                .foregroundStyle(Color(theme.dimForeground))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, register.activityVerticalPadding)
        .padding(.top, spacing.top)
        .padding(.bottom, spacing.bottom)
        .accessibilityElement(children: .combine)
    }

    private func pendingAsk(_ ask: PendingAsk) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                Text(ask.promptSummary)
                    .font(.body.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: ask.kind == .permission ? "hand.raised" : "questionmark.circle")
                    .foregroundStyle(Color(theme.faintForeground))
            }
            if ask.options.isEmpty {
                Text(AgentGUIL10n.string(
                    "agent.ask.terminalRequired",
                    defaultValue: "Answer this request in Terminal."
                ))
                .font(spacing.density.metadataFont)
                .foregroundStyle(Color(theme.dimForeground))
                terminalButton
            } else {
                ForEach(Array(ask.options.enumerated()), id: \.offset) { index, option in
                    Button {
                        onAnswer(ask, index)
                    } label: {
                        HStack {
                            Text(option)
                                .multilineTextAlignment(.leading)
                            Spacer(minLength: 8)
                            if answeringAskID == ask.id {
                                ProgressView()
                                    .controlSize(.small)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.bordered)
                    .disabled(answeringAskID != nil)
                    .accessibilityIdentifier("AgentAskOption-\(index)")
                }
            }
            if failedAskID == ask.id {
                Text(AgentGUIL10n.string(
                    "agent.ask.failed",
                    defaultValue: "The answer could not be sent. Try again or use Terminal."
                ))
                .font(spacing.density.metadataFont)
                .foregroundStyle(.red)
                terminalButton
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .padding(.top, spacing.top)
        .padding(.bottom, spacing.bottom)
        .background(Color(theme.hoverBackground).opacity(0.55), in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal, 18)
    }

    private var terminalButton: some View {
        Button {
            onShowTerminal()
        } label: {
            Text(AgentGUIL10n.string("agent.ask.showTerminal", defaultValue: "Show Terminal"))
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier("AgentAskShowTerminal")
    }

    private func symbol(for kind: String) -> String {
        switch kind.lowercased() {
        case "command":
            "terminal"
        case "file":
            "doc.text"
        case "question":
            "questionmark.circle"
        case "permission":
            "hand.raised"
        case "thought":
            "brain"
        default:
            "sparkle.magnifyingglass"
        }
    }

}
#endif
