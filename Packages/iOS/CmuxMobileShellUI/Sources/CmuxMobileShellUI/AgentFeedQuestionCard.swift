#if os(iOS)
import CmuxMobileShellModel
import SwiftUI

struct AgentFeedQuestionCard: View {
    let question: MobileAgentFeedQuestion
    let index: Int
    @Binding var draft: AgentFeedQuestionAnswerBuilder.Draft
    var focusedCustomAnswerID: FocusState<String?>.Binding
    let customAnswerHeightChanged: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(String(
                    format: String(
                        localized: "mobile.agentFeed.question.pageLabel",
                        defaultValue: "Question %lld",
                        bundle: .module
                    ),
                    Int64(index + 1)
                ))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Label(String(
                    localized: "mobile.agentFeed.question.answeredShort",
                    defaultValue: "Answered",
                    bundle: .module
                ), systemImage: "checkmark")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.green)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Color.green.opacity(0.12), in: Capsule())
                .opacity(draft.hasAnswer ? 1 : 0)
                .accessibilityHidden(!draft.hasAnswer)
            }

            if let header = question.header, !header.isEmpty {
                Text(header)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            AgentFeedMarkdownText(markdown: question.prompt, font: .title3.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)

            if question.multiSelect {
                Text(String(
                    localized: "mobile.agentFeed.question.multiSelect",
                    defaultValue: "Select all that apply",
                    bundle: .module
                ))
                .font(.footnote)
                .foregroundStyle(.secondary)
            }

            if !question.options.isEmpty {
                VStack(spacing: question.multiSelect ? 8 : 0) {
                    ForEach(Array(question.options.enumerated()), id: \.element.id) { index, option in
                        AgentFeedQuestionOptionRow(
                            question: question,
                            option: option,
                            isSelected: draft.selectedOptionIDs.contains(option.id),
                            action: {
                                focusedCustomAnswerID.wrappedValue = nil
                                draft.toggleOption(option.id, multiSelect: question.multiSelect)
                            }
                        )
                        if !question.multiSelect, index < question.options.count - 1 {
                            Divider()
                                .padding(.leading, 44)
                        }
                    }
                }
                .padding(4)
                .background(
                    Color.primary.opacity(0.035),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                )
            }

            AgentFeedQuestionCustomAnswerRow(
                questionID: question.id,
                multiSelect: question.multiSelect,
                isSelected: draft.isCustomAnswerSelected,
                text: $draft.customText,
                focusedQuestionID: focusedCustomAnswerID,
                select: { draft.selectCustomAnswer() }
            )
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { _ in
                customAnswerHeightChanged()
            }
        }
        .padding(14)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.secondary.opacity(0.16), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("MobileAgentFeedQuestionCard-\(question.id)")
    }
}
#endif
