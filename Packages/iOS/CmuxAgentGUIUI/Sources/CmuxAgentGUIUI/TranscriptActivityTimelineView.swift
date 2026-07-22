#if os(iOS)
public import CMUXMobileCore
import CmuxAgentGUIProjection
public import SwiftUI

/// Sheet content showing the ordered activity timeline for one completed turn.
public struct TranscriptActivityTimelineView: View {
    private let details: TranscriptActivityDetails
    private let theme: AgentGUITheme

    /// Creates a turn activity timeline.
    /// - Parameters:
    ///   - details: Immutable activity-detail payload for the selected turn.
    ///   - terminalTheme: Current terminal theme used to derive the transcript palette.
    public init(details: TranscriptActivityDetails, terminalTheme: TerminalTheme) {
        self.details = details
        theme = AgentGUITheme(terminalTheme: terminalTheme)
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    Text(AgentGUIL10n.activitySummary(details.summary))
                        .font(.subheadline)
                        .foregroundStyle(Color(theme.dimForeground))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Divider()
                    ForEach(details.summary.items) { item in
                        TranscriptActivityItemView(
                            item: item,
                            theme: theme,
                            density: .comfortable
                        )
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
            }
            .background(Color(theme.background))
            .navigationTitle(AgentGUIL10n.string(
                "agent.activity.details.title",
                defaultValue: "Activity"
            ))
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
#endif
