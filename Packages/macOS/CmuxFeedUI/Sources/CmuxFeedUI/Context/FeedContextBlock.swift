public import SwiftUI
public import CMUXAgentLaunch

/// Compact summary of the conversation context near a Feed event: the last user
/// message, the assistant preamble, and the active plan summary. Claude markdown
/// is rendered for Claude-sourced workstreams.
public struct FeedContextBlock: View {
    let context: WorkstreamContext
    let source: WorkstreamSource

    /// Creates a Feed context block.
    /// - Parameters:
    ///   - context: The conversation context snapshot to summarize.
    ///   - source: The workstream's agent source, used to decide markdown rendering.
    public init(context: WorkstreamContext, source: WorkstreamSource) {
        self.context = context
        self.source = source
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let user = context.lastUserMessage {
                FeedLabeledTextRow(
                    label: String(localized: "feed.context.you", defaultValue: "You:", bundle: .main),
                    text: user,
                    labelColor: .secondary,
                    textColor: .secondary
                )
            }
            if let preamble = context.assistantPreamble {
                FeedLabeledTextRow(
                    label: agentLabel,
                    text: preamble,
                    labelColor: .secondary,
                    textColor: .secondary,
                    rendersMarkdown: source == .claude
                )
            }
            if let plan = context.planSummary {
                FeedLabeledTextRow(
                    label: String(localized: "feed.context.plan", defaultValue: "Plan:", bundle: .main),
                    text: plan,
                    labelColor: Color.purple.opacity(0.85),
                    textColor: .secondary,
                    rendersMarkdown: source == .claude
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var agentLabel: String {
        "\(source.rawValue.capitalized):"
    }
}
