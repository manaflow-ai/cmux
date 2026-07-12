#if os(iOS)
import CmuxAgentGUIProjection
import SwiftUI

struct TranscriptActivitySummaryView: View {
    let isExpanded: Bool
    let summary: TranscriptActivitySummary
    let theme: AgentGUITheme
    let onToggleExpanded: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Button {
                onToggleExpanded()
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .foregroundStyle(Color(theme.faintForeground))
                        .accessibilityHidden(true)
                    Text(AgentGUIL10n.activitySummary(summary))
                        .font(.footnote)
                        .foregroundStyle(Color(theme.faintForeground))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .frame(height: 26)
            }
            .frame(minHeight: 44)
            .buttonStyle(.plain)
            .accessibilityLabel(AgentGUIL10n.activitySummary(summary))
            .accessibilityValue(isExpanded
                ? AgentGUIL10n.string("agent.activity.expanded", defaultValue: "Expanded")
                : AgentGUIL10n.string("agent.activity.collapsed", defaultValue: "Collapsed"))
            .accessibilityHint(AgentGUIL10n.string(
                "agent.activity.toggleHint",
                defaultValue: "Shows or hides completed activity"
            ))

            if isExpanded {
                VStack(spacing: 1) {
                    ForEach(summary.items) { item in
                        TranscriptActivityItemView(item: item, theme: theme)
                    }
                }
            }
        }
    }
}
#endif
