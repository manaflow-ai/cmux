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

    private var answeredCount: Int {
        questions.reduce(into: 0) { count, question in
            if drafts[question.id]?.hasAnswer == true { count += 1 }
        }
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
            .navigationTitle(String(
                localized: "mobile.agentFeed.question.answerTitle",
                defaultValue: "Answer questions",
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
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        submit()
                    } label: {
                        Text(String(
                            localized: "mobile.agentFeed.question.submitShort",
                            defaultValue: "Submit",
                            bundle: .module
                        ))
                        .font(.subheadline.weight(.semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .buttonBorderShape(.capsule)
                    .disabled(submittedAnswers == nil)
                    .accessibilityIdentifier("MobileAgentFeedQuestionSubmit")
                }
            }
        }
        .presentationDragIndicator(.visible)
        .accessibilityIdentifier("MobileAgentFeedQuestionComposer")
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                ZStack {
                    Circle()
                        .fill(Color.accentColor.opacity(0.16))
                        .frame(width: 30, height: 30)
                    Image(systemName: "questionmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Color.accentColor)
                }
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(
                        localized: "mobile.agentFeed.question.pendingTitle",
                        defaultValue: "Needs your input",
                        bundle: .module
                    ))
                    .font(.headline)
                    Text(String(
                        localized: "mobile.agentFeed.question.answerSubtitle",
                        defaultValue: "Choose an option or write an answer for each prompt.",
                        bundle: .module
                    ))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 8) {
                ProgressView(value: Double(answeredCount), total: Double(max(questions.count, 1)))
                    .tint(Color.accentColor)
                    .frame(height: 4)
                Text(verbatim: "\(answeredCount)/\(questions.count)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .accessibilityLabel(Text(String(
                        format: String(
                            localized: "mobile.agentFeed.question.progressSummary",
                            defaultValue: "%lld of %lld answered",
                            bundle: .module
                        ),
                        Int64(answeredCount),
                        Int64(questions.count)
                    )))
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func questionCard(_ question: MobileAgentFeedQuestion, index: Int) -> some View {
        let draft = drafts[question.id] ?? AgentFeedQuestionAnswerBuilder.Draft()
        return VStack(alignment: .leading, spacing: 14) {
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
                if draft.hasAnswer {
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
                }
            }

            if let header = question.header, !header.isEmpty {
                Text(header)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Text(question.prompt)
                .font(.title3.weight(.semibold))
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

            VStack(spacing: 0) {
                ForEach(Array(question.options.enumerated()), id: \.element.id) { index, option in
                    AgentFeedQuestionOptionRow(
                        question: question,
                        option: option,
                        isSelected: draft.selectedOptionIDs.contains(option.id),
                        action: { toggle(option, for: question) }
                    )
                    if index < question.options.count - 1 {
                        Divider()
                            .padding(.leading, 44)
                    }
                }
            }
            .padding(.vertical, 4)
            .background(
                Color.primary.opacity(0.035),
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )

            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "pencil.line")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .accessibilityHidden(true)
                TextField(String(
                    localized: "mobile.agentFeed.question.otherPlaceholder",
                    defaultValue: "Your answer",
                    bundle: .module
                ), text: customTextBinding(for: question), axis: .vertical)
                .textFieldStyle(.plain)
                .font(.body)
                .lineLimit(2...5)
                .accessibilityIdentifier("MobileAgentFeedQuestionText-\(question.id)")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(minHeight: 48)
            .background(
                Color.primary.opacity(0.055),
                in: RoundedRectangle(cornerRadius: 11, style: .continuous)
            )
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

    private func submit() {
        guard let submittedAnswers else { return }
        actions.questionReply(context.item, submittedAnswers)
        dismiss()
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
