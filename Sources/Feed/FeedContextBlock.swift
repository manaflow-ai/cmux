import CMUXAgentLaunch
import SwiftUI

struct FeedContextBlock: View {
    let context: WorkstreamContext
    let source: WorkstreamSource

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let user = context.lastUserMessage {
                FeedLabeledTextRow(
                    label: String(localized: "feed.context.you", defaultValue: "You:"),
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
                    label: String(localized: "feed.context.plan", defaultValue: "Plan:"),
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

