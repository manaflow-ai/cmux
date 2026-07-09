public import CMUXAgentLaunch
public import SwiftUI

/// Compact recap of the latest exchange in a workstream: the user's last
/// message, the assistant preamble, and a plan summary. Claude-sourced prose
/// renders inline markdown.
///
/// The `feed.context.*` localization keys are resolved against the app's main
/// bundle (`bundle: .main`) so the app-side `.xcstrings` catalog and its
/// non-English translations keep working when this view is hosted from the
/// package rather than the app target.
public struct FeedContextBlock: View {
    let context: WorkstreamContext
    let source: WorkstreamSource

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
