#if os(iOS)
import CmuxAgentGUIProjection
import SwiftUI

struct TranscriptRowContentView: View {
    let row: TranscriptRow
    let spacing: TranscriptRowSpacing
    let theme: AgentGUITheme

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
        case .streaming(let textTail):
            bubble(text: textTail, alignment: .leading, style: .streaming)
                .opacity(0.82)
        case .genericActivity(let activity):
            activityRow(activity)
        case .activitySummary(let summary):
            TranscriptActivitySummaryView(summary: summary, theme: theme)
                .padding(.horizontal, 24)
                .padding(.top, spacing.top)
                .padding(.bottom, spacing.bottom)
        case .activityItem(let item):
            TranscriptActivityItemView(item: item, theme: theme)
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
            Text(text)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .foregroundStyle(style.foreground(theme: theme))
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
        Text(text)
            .font(.body)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            .foregroundStyle(Color(theme.foreground))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.top, spacing.top)
            .padding(.bottom, spacing.bottom)
            .accessibilityLabel(text)
    }

    private func centered(label: String) -> some View {
        Text(label)
            .font(.footnote)
            .foregroundStyle(Color(theme.faintForeground))
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 20)
            .padding(.vertical, 4)
            .padding(.top, spacing.top)
            .padding(.bottom, spacing.bottom)
            .accessibilityLabel(label)
    }

    private func activityRow(_ activity: TranscriptGenericActivity) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol(for: activity.kindLabel))
                .foregroundStyle(Color(theme.faintForeground))
            Text(AgentGUIL10n.activityKind(activity.kindLabel))
                .font(.footnote.weight(.semibold))
            Text(activity.summary)
                .font(.footnote)
                .foregroundStyle(Color(theme.dimForeground))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 4)
        .padding(.top, spacing.top)
        .padding(.bottom, spacing.bottom)
        .accessibilityElement(children: .combine)
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
