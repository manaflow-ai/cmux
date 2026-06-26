import CMUXAgentLaunch
public import SwiftUI

/// Renders plan text as a stack of small structured sections. Block
/// headings, lists, and paragraphs keep the Feed's compact rhythm, while
/// Claude markdown inside each line gets parsed tastefully. Heading text
/// intentionally stays at body scale.
public struct PlanBodyView: View {
    let plan: String
    let rendersMarkdown: Bool

    public init(plan: String, rendersMarkdown: Bool) {
        self.plan = plan
        self.rendersMarkdown = rendersMarkdown
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let text):
                    markdownText(
                        text,
                        weight: .semibold,
                        color: .primary.opacity(0.95)
                    )
                        .padding(.top, 2)
                case .paragraph(let text):
                    markdownText(text, color: .primary.opacity(0.85))
                case .numbered(let items):
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                            HStack(alignment: .top, spacing: 5) {
                                Text("\(item.index).")
                                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                                    .foregroundColor(.secondary)
                                markdownText(item.text, color: .primary.opacity(0.85))
                            }
                        }
                    }
                case .bulleted(let items):
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                            HStack(alignment: .top, spacing: 8) {
                                Circle()
                                    .fill(Color.blue.opacity(0.85))
                                    .frame(width: 3.5, height: 3.5)
                                    .padding(.top, 5.5)
                                    .frame(width: 10, alignment: .center)
                                markdownText(item, color: .primary.opacity(0.85))
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func markdownText(
        _ text: String,
        weight: Font.Weight? = nil,
        color: Color
    ) -> some View {
        if rendersMarkdown {
            FeedMarkdownInlineText(
                text: text,
                fontSize: 11,
                weight: weight,
                foregroundColor: color
            )
        } else {
            Text(text)
                .font(.system(size: 11, weight: weight ?? .regular))
                .foregroundColor(color)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var blocks: [WorkstreamPlanLayout.Block] {
        WorkstreamPlanLayout(plan: plan).blocks
    }
}
