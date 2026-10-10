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
            header

            if let firstQuestion = item.questions.first {
                questionPreview(firstQuestion)
            }
        }
        .padding(14)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.accentColor.opacity(0.24), lineWidth: 1)
        }
        .disabled(isReplyPending)
        .opacity(isReplyPending ? 0.55 : 1)
        .padding(.top, 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("MobileAgentFeedQuestionControls")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(String(
                localized: "mobile.agentFeed.question.pendingTitle",
                defaultValue: "Needs your input",
                bundle: .module
            ))
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.primary)
            Text(String(
                localized: "mobile.agentFeed.question.count",
                defaultValue: "\(Int64(item.questions.count)) questions",
                bundle: .module
            ))
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func questionPreview(_ question: MobileAgentFeedQuestion) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let header = question.header, !header.isEmpty {
                Text(header)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            AgentFeedMarkdownText(
                markdown: question.prompt,
                font: .body.weight(.semibold),
                lineLimit: 4
            )
            .fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .center, spacing: 8) {
                if question.multiSelect {
                    Label(String(
                        localized: "mobile.agentFeed.question.multiSelect",
                        defaultValue: "Select all that apply",
                        bundle: .module
                    ), systemImage: "checkmark.square")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } else {
                    Text(String(
                        localized: "mobile.agentFeed.question.singleSelect",
                        defaultValue: "Choose one",
                        bundle: .module
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                answerButton
            }
        }
    }

    private var answerButton: some View {
        Button {
            actions.beginCompose(item, .question)
        } label: {
            Label(String(
                localized: "mobile.agentFeed.question.answer",
                defaultValue: "Answer",
                bundle: .module
            ), systemImage: "arrow.up.right")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(Color.accentColor.opacity(0.14), in: Capsule())
            .overlay {
                Capsule()
                    .stroke(Color.accentColor.opacity(0.3), lineWidth: 1)
            }
            // Hit testing belongs to the label, including its invisible padding.
            .frame(minWidth: 84, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("MobileAgentFeedQuestionAnswer")
    }
}
#endif
