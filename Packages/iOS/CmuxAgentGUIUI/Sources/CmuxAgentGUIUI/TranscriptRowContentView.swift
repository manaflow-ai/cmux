#if os(iOS)
import CmuxAgentGUIProjection
import SwiftUI

struct TranscriptRowContentView: View {
    let row: TranscriptRow
    let spacing: TranscriptRowSpacing

    var body: some View {
        switch row.rowKind {
        case .proseAgent(let text, let grouping):
            bubble(text: text, alignment: .leading, style: .agent, grouping: grouping)
        case .proseUser(let text, _, let grouping):
            bubble(text: text, alignment: .trailing, style: .user, grouping: grouping)
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
            bubble(text: ticket.text, alignment: .trailing, style: .pending, grouping: .single)
        case .streaming(let textTail):
            bubble(text: textTail, alignment: .leading, style: .streaming, grouping: .single)
                .opacity(0.82)
        case .genericActivity(let activity):
            activityRow(activity)
        case .unsupported(let rawKind, let summary):
            activityRow(TranscriptGenericActivity(kindLabel: rawKind, summary: summary))
        }
    }

    private func bubble(
        text: String,
        alignment: HorizontalAlignment,
        style: BubbleStyle,
        grouping: TranscriptProseGrouping
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
                .foregroundStyle(style.foreground)
                .background(style.background, in: RoundedRectangle(cornerRadius: cornerRadius(grouping), style: .continuous))
                .accessibilityLabel(text)
            if alignment == .leading {
                Spacer(minLength: 42)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, spacing.top)
        .padding(.bottom, spacing.bottom)
    }

    private func centered(label: String) -> some View {
        Text(label)
            .font(.footnote)
            .foregroundStyle(.secondary)
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
                .foregroundStyle(.secondary)
            Text(AgentGUIL10n.activityKind(activity.kindLabel))
                .font(.footnote.weight(.semibold))
            Text(activity.summary)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 4)
        .padding(.top, spacing.top)
        .padding(.bottom, spacing.bottom)
        .accessibilityElement(children: .combine)
    }

    private func cornerRadius(_ grouping: TranscriptProseGrouping) -> CGFloat {
        switch grouping {
        case .single:
            18
        case .first, .last:
            16
        case .middle:
            12
        }
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
