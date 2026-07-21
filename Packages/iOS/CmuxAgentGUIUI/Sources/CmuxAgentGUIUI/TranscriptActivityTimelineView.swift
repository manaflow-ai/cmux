#if os(iOS)
public import CMUXMobileCore
public import CmuxAgentGUIProjection
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
                        AgentActivityDetailItemView(
                            model: TranscriptActivityDetailModel(item: item),
                            kind: item.kind,
                            theme: theme
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

private struct AgentActivityDetailItemView: View {
    let model: TranscriptActivityDetailModel
    let kind: TranscriptActivityKind
    let theme: AgentGUITheme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(model.title, systemImage: symbol)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
            ForEach(model.sections) { section in
                VStack(alignment: .leading, spacing: 4) {
                    Text(AgentGUIL10n.activityDetailLabel(section.label))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color(theme.faintForeground))
                    Text(section.value)
                        .font(section.isCode ? .system(.footnote, design: .monospaced) : .footnote)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .foregroundStyle(Color(theme.foreground))
        .padding(14)
        .background(Color(theme.raisedBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    private var symbol: String {
        switch kind {
        case .assistant: "text.bubble"
        case .thought: "brain"
        case .command: "terminal"
        case .tool: "wrench.and.screwdriver"
        case .file: "doc.text"
        case .question: "questionmark.circle"
        case .permission: "hand.raised"
        case .status: "info.circle"
        case .attachment: "paperclip"
        case .unknown: "ellipsis.circle"
        }
    }
}
#endif
