#if os(iOS)
import CmuxAgentGUIProjection
import SwiftUI

struct TranscriptActivityItemView: View {
    let item: TranscriptActivityItem
    let theme: AgentGUITheme

    var body: some View {
        HStack(spacing: 7) {
            if item.isRunning {
                ProgressView()
                    .controlSize(.mini)
                    .tint(Color(theme.accent))
                    .frame(width: 12, height: 12)
            } else {
                Image(systemName: item.kind.symbolName)
                    .font(.system(size: 9, weight: .regular))
                    .foregroundStyle(Color(theme.faintForeground))
                    .frame(width: 12, height: 12)
                    .accessibilityHidden(true)
            }
            Text(AgentGUIL10n.activityKind(item.kind))
                .font(.footnote.weight(.medium))
                .foregroundStyle(Color(theme.dimForeground))
            Text(item.summary)
                .font(.footnote)
                .foregroundStyle(Color(theme.faintForeground))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .frame(minHeight: 24, maxHeight: 24)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(AgentGUIL10n.activityAccessibility(item))
    }
}

private extension TranscriptActivityKind {
    var symbolName: String {
        switch self {
        case .assistant: "text.bubble"
        case .thought: "brain"
        case .command: "terminal"
        case .tool: "wrench.and.screwdriver"
        case .file: "doc.text"
        case .question: "questionmark.circle"
        case .permission: "hand.raised"
        case .status: "info.circle"
        case .attachment: "paperclip"
        case .unknown: "sparkle.magnifyingglass"
        }
    }
}
#endif
