#if os(iOS)
import CmuxAgentGUIProjection
import SwiftUI
import UIKit

struct TranscriptActivityItemView: View {
    let item: TranscriptActivityItem
    let theme: AgentGUITheme
    let density: TranscriptDensity

    private var register: TranscriptRowSpacingRegister {
        TranscriptRowSpacing.register(for: density)
    }

    private var errorColor: Color {
        Color(uiColor: theme.error.map { UIColor($0) } ?? .systemRed)
    }

    var body: some View {
        HStack(spacing: 7) {
            if item.isRunning && !item.isFailed {
                TranscriptActivityProgressView(color: UIColor(theme.accent))
                    .frame(width: 12, height: 12)
            } else {
                Image(systemName: item.isFailed ? "exclamationmark.circle.fill" : item.kind.symbolName)
                    .font(.system(size: 9, weight: .regular))
                    .foregroundStyle(item.isFailed ? errorColor : Color(theme.faintForeground))
                    .frame(width: 12, height: 12)
                    .accessibilityHidden(true)
            }
            Text(AgentGUIL10n.activityKind(item.kind))
                .font(density.metadataFont.weight(.medium))
                .foregroundStyle(item.isFailed ? errorColor : Color(theme.dimForeground))
            Text(AgentGUIL10n.activityDetail(item))
                .font(density.metadataFont)
                .foregroundStyle(item.isFailed ? errorColor : Color(theme.faintForeground))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .frame(height: register.activityItemHeight)
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
