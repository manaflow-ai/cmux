#if os(iOS)
import CmuxMobileShellModel
import SwiftUI

/// Presents all prompts in one scrollable answer sheet before submission.
struct AgentFeedQuestionComposer: View {
    let context: AgentFeedComposeContext
    let actions: AgentFeedActions
    @Environment(\.dismiss) private var dismiss
    @State private var drafts: [String: AgentFeedQuestionAnswerBuilder.Draft] = [:]
    @FocusState private var focusedCustomAnswerID: String?

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
                    AgentFeedQuestionComposerIntro(
                        answeredCount: answeredCount,
                        questionCount: questions.count
                    )
                    ForEach(Array(questions.enumerated()), id: \.element.id) { index, question in
                        AgentFeedQuestionCard(
                            question: question,
                            index: index,
                            draft: Binding(
                                get: { drafts[question.id] ?? AgentFeedQuestionAnswerBuilder.Draft() },
                                set: { drafts[question.id] = $0 }
                            ),
                            focusedCustomAnswerID: $focusedCustomAnswerID
                        )
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
                        .foregroundStyle(.white)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .buttonBorderShape(.capsule)
                    .disabled(submittedAnswers == nil)
                    .accessibilityIdentifier("MobileAgentFeedQuestionSubmit")
                }
            }
        }
        .onChange(of: focusedCustomAnswerID) { _, questionID in
            guard let questionID else { return }
            drafts[questionID, default: AgentFeedQuestionAnswerBuilder.Draft()].selectCustomAnswer()
        }
        .presentationDragIndicator(.visible)
        .accessibilityIdentifier("MobileAgentFeedQuestionComposer")
    }

    private func submit() {
        guard let submittedAnswers else { return }
        actions.questionReply(context.item, submittedAnswers)
        dismiss()
    }
}

private struct AgentFeedQuestionComposerIntro: View {
    let answeredCount: Int
    let questionCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
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

            HStack(spacing: 8) {
                ProgressView(value: Double(answeredCount), total: Double(max(questionCount, 1)))
                    .tint(Color.accentColor)
                    .frame(height: 4)
                Text(verbatim: "\(answeredCount)/\(questionCount)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .accessibilityLabel(Text(String(
                        localized: "mobile.agentFeed.question.progressSummary",
                        defaultValue: "\(Int64(answeredCount)) of \(Int64(questionCount)) answered",
                        bundle: .module
                    )))
            }
        }
        .accessibilityElement(children: .combine)
    }
}
#endif
