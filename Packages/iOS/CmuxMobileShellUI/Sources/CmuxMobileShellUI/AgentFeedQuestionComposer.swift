#if os(iOS)
import CmuxMobileShellModel
import SwiftUI

/// Presents all prompts in one scrollable answer sheet before submission.
struct AgentFeedQuestionComposer: View {
    let context: AgentFeedComposeContext
    let actions: AgentFeedActions
    @Environment(\.dismiss) private var dismiss
    @State private var drafts: [String: AgentFeedQuestionAnswerBuilder.Draft] = [:]

    private let answerBuilder = AgentFeedQuestionAnswerBuilder()

    private var questions: [MobileAgentFeedQuestion] {
        context.item.questions
    }

    private var submittedAnswers: [String]? {
        answerBuilder.answers(for: questions, drafts: drafts)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    intro
                    ForEach(Array(questions.enumerated()), id: \.element.id) { index, question in
                        questionCard(question, index: index)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 24)
            }
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                submitBar
            }
            .navigationTitle(String(
                localized: "mobile.agentFeed.question.answerTitle",
                defaultValue: "Answer the questions",
                bundle: .module
            ))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(String(
                        localized: "mobile.agentFeed.compose.cancel",
                        defaultValue: "Cancel",
                        bundle: .module
                    )) {
                        dismiss()
                    }
                }
            }
        }
        .presentationDragIndicator(.visible)
        .accessibilityIdentifier("MobileAgentFeedQuestionComposer")
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(
                String(
                    localized: "mobile.agentFeed.question.pendingTitle",
                    defaultValue: "Your agent needs an answer",
                    bundle: .module
                ),
                systemImage: "questionmark.circle.fill"
            )
            .font(.headline)
            .foregroundStyle(.primary)
            Text(String(
                localized: "mobile.agentFeed.question.answerSubtitle",
                defaultValue: "Choose an option or write an answer for each prompt.",
                bundle: .module
            ))
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private func questionCard(_ question: MobileAgentFeedQuestion, index: Int) -> some View {
        let draft = drafts[question.id] ?? AgentFeedQuestionAnswerBuilder.Draft()
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(String(
                    format: L10n.string(
                        "mobile.agentFeed.question.pageLabel",
                        defaultValue: "Question %lld",
                        bundle: .module
                    ),
                    Int64(index + 1)
                ))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if draft.hasAnswer {
                    Label(String(
                        localized: "mobile.agentFeed.question.answeredShort",
                        defaultValue: "Answered",
                        bundle: .module
                    ), systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.green)
                }
            }

            if let header = question.header, !header.isEmpty {
                Text(header)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Text(question.prompt)
                .font(.body.weight(.semibold))
                .foregroundStyle(.primary)
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

            ForEach(question.options, id: \.id) { option in
                AgentFeedQuestionOptionRow(
                    question: question,
                    option: option,
                    isSelected: draft.selectedOptionIDs.contains(option.id),
                    action: { toggle(option, for: question) }
                )
            }

            TextField(String(
                localized: "mobile.agentFeed.question.otherPlaceholder",
                defaultValue: "Your answer",
                bundle: .module
            ), text: customTextBinding(for: question), axis: .vertical)
            .textFieldStyle(.plain)
            .font(.body)
            .lineLimit(2...5)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(minHeight: 52)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            .accessibilityIdentifier("MobileAgentFeedQuestionText-\(question.id)")
        }
        .padding(16)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.secondary.opacity(0.14), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("MobileAgentFeedQuestionCard-\(question.id)")
    }

    private var submitBar: some View {
        VStack(spacing: 0) {
            Divider()
            Button {
                guard let submittedAnswers else { return }
                actions.questionReply(context.item, submittedAnswers)
                dismiss()
            } label: {
                Text(String(
                    localized: "mobile.agentFeed.question.submitAll",
                    defaultValue: "Submit all answers",
                    bundle: .module
                ))
                .font(.body.weight(.semibold))
                .frame(maxWidth: .infinity)
                .frame(height: 48)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(submittedAnswers == nil)
            .accessibilityIdentifier("MobileAgentFeedQuestionSubmit")
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(.bar)
    }

    private func customTextBinding(
        for question: MobileAgentFeedQuestion
    ) -> Binding<String> {
        Binding(
            get: { drafts[question.id]?.customText ?? "" },
            set: { newValue in
                let current = drafts[question.id] ?? AgentFeedQuestionAnswerBuilder.Draft()
                drafts[question.id] = AgentFeedQuestionAnswerBuilder.Draft(
                    selectedOptionIDs: newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? current.selectedOptionIDs
                        : [],
                    customText: newValue
                )
            }
        )
    }

    private func toggle(
        _ option: MobileAgentFeedQuestionOption,
        for question: MobileAgentFeedQuestion
    ) {
        let current = drafts[question.id] ?? AgentFeedQuestionAnswerBuilder.Draft()
        var selected = current.selectedOptionIDs
        if question.multiSelect {
            if selected.contains(option.id) {
                selected.remove(option.id)
            } else {
                selected.insert(option.id)
            }
        } else {
            selected = [option.id]
        }
        drafts[question.id] = AgentFeedQuestionAnswerBuilder.Draft(
            selectedOptionIDs: selected,
            customText: ""
        )
    }
}
#endif
