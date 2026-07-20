#if os(iOS)
import CmuxAgentGUIProjection
import SwiftUI

struct TranscriptActivitySummaryView: View {
    let summary: TranscriptActivitySummary
    let theme: AgentGUITheme
    let density: TranscriptDensity
    let onOpen: () -> Void

    private var register: TranscriptRowSpacingRegister {
        TranscriptRowSpacing.register(for: density)
    }

    var body: some View {
        Button {
            onOpen()
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color(theme.faintForeground))
                    .accessibilityHidden(true)
                Text(AgentGUIL10n.activitySummary(summary))
                    .font(density.metadataFont)
                    .foregroundStyle(Color(theme.faintForeground))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .frame(height: register.activitySummaryLabelHeight)
        }
        .frame(minHeight: register.activitySummaryMinimumHeight)
        .buttonStyle(.plain)
        .accessibilityLabel(AgentGUIL10n.activitySummary(summary))
        .accessibilityHint(AgentGUIL10n.string(
            "agent.activity.openHint",
            defaultValue: "Opens activity details"
        ))
    }
}
#endif
