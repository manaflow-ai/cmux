#if os(iOS)
import CmuxMobileShellModel
import SwiftUI

/// Keeps a pending question row compact and opens the full answer sheet.
struct AgentFeedQuestionControls: View {
    let item: MobileAgentFeedItem
    let isReplyPending: Bool
    let actions: AgentFeedActions

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label(String(
                    localized: "mobile.agentFeed.question.pendingTitle",
                    defaultValue: "Your agent needs an answer",
                    bundle: .module
                ), systemImage: "questionmark.circle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                Spacer(minLength: 0)
                Text(verbatim: "\(item.questions.count)")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.secondary.opacity(0.12), in: Capsule())
                    .accessibilityLabel(Text(String(
                        format: L10n.string(
                            "mobile.agentFeed.question.progress",
                            defaultValue: "Question %lld of %lld",
                            bundle: .module
                        ),
                        Int64(1),
                        Int64(item.questions.count)
                    )))
            }

            if let firstQuestion = item.questions.first {
                if let header = firstQuestion.header, !header.isEmpty {
                    Text(header)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                Text(firstQuestion.prompt)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                actions.beginCompose(item, .question)
            } label: {
                Label(String(
                    localized: "mobile.agentFeed.question.answer",
                    defaultValue: "Answer",
                    bundle: .module
                ), systemImage: "arrow.up.right.circle.fill")
                .font(.body.weight(.semibold))
                .frame(maxWidth: .infinity)
                .frame(height: 44)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .accessibilityIdentifier("MobileAgentFeedQuestionAnswer")
        }
        .padding(14)
        .background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.accentColor.opacity(0.22), lineWidth: 1)
        }
        .disabled(isReplyPending)
        .opacity(isReplyPending ? 0.55 : 1)
        .padding(.top, 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("MobileAgentFeedQuestionControls")
    }
}
#endif
