public import AppKit
public import SwiftUI

public import CMUXAgentLaunch

import CmuxAppKitSupportUI

/// Renders the action area for an interview / long-form question feed row.
///
/// One ``QuestionActionArea`` drives the full ``WorkstreamQuestionPrompt`` set
/// for a row. Layout follows ``WorkstreamQuestionInterview``: a single rich
/// long-form question becomes tappable option cards plus an optional custom
/// answer card, while a multi-question batch becomes numbered blocks of option
/// pills with a per-question free-form field. A submit button composes the
/// per-question answers into a reply; when the prompt set looks like a plan
/// interview a "Skip + plan immediately" CTA is offered alongside it.
///
/// The view owns only transient editor state (per-question `selections`,
/// `freeTexts`, and custom-answer focus); all data is passed in as immutable
/// props plus action closures, so it never observes the live store. Localized
/// strings resolve against the app's main bundle (`bundle: .main`) because the
/// `feed.question.*` / `feed.badge.*` keys live in the app catalog, not the
/// package bundle.
///
/// The two keyboard-focus seams required by ``FeedInlineTextField`` are
/// injected as closures rather than referencing the app's `AppDelegate` or the
/// `FeedKeyboardFocusView` directly:
///
/// - `moveFocusToFeedHost` asks the app to move keyboard focus to the Feed
///   sidebar host for a given window, returning `true` when it did.
/// - `responderRetainsFeedFocus` lets the app decide whether a window's new
///   first responder still belongs to the Feed focus domain, so end-of-editing
///   does not spuriously fire `onBlur` while focus hops within the Feed sidebar.
public struct QuestionActionArea: View {
    let questions: [WorkstreamQuestionPrompt]
    let source: WorkstreamSource
    let status: WorkstreamStatus
    let isRowSelected: Bool
    let onFocusRow: () -> Void
    let onActionRow: () -> Void
    let onBlurRow: () -> Void
    let context: WorkstreamContext?
    let onReply: ([String]) -> Void
    let moveFocusToFeedHost: @MainActor (NSWindow) -> Bool
    let responderRetainsFeedFocus: (NSResponder) -> Bool

    private static let skipInterviewAndPlanAnswer = "Skip interview and plan immediately"
    private static let customAnswerSelectionId = "__cmux_custom_answer__"

    // Per-question selections keyed by question id.
    @State private var selections: [String: Set<String>] = [:]
    // Per-question "Type something…" free-form answers. When
    // non-empty, wins over preset option selections for that
    // question — mirrors Claude's TUI fallback.
    @State private var freeTexts: [String: String] = [:]
    @State private var customAnswerFocusKey: String?
    @State private var customAnswerFocusRequest = 0

    /// Creates the question action area for a feed row.
    /// - Parameters:
    ///   - questions: The prompt set to render and answer.
    ///   - source: The agent that raised the questions.
    ///   - status: The prompt set's pending/resolved status.
    ///   - isRowSelected: Whether the owning row is selected (clears custom
    ///     answer focus when deselected).
    ///   - onFocusRow: Invoked when a free-form / custom answer field gains focus.
    ///   - onActionRow: Invoked before a selection or submit to mark the row as
    ///     acted on.
    ///   - onBlurRow: Invoked when a free-form / custom answer field loses focus.
    ///   - context: The optional display context driving long-form / plan
    ///     interview detection.
    ///   - onReply: Invoked with the composed per-question answer strings.
    ///   - moveFocusToFeedHost: Focus seam for ``FeedInlineTextField`` — moves
    ///     keyboard focus to the Feed sidebar host for a window.
    ///   - responderRetainsFeedFocus: Focus seam for ``FeedInlineTextField`` —
    ///     reports whether a responder still belongs to the Feed focus domain.
    public init(
        questions: [WorkstreamQuestionPrompt],
        source: WorkstreamSource,
        status: WorkstreamStatus,
        isRowSelected: Bool,
        onFocusRow: @escaping () -> Void,
        onActionRow: @escaping () -> Void,
        onBlurRow: @escaping () -> Void,
        context: WorkstreamContext?,
        onReply: @escaping ([String]) -> Void,
        moveFocusToFeedHost: @escaping @MainActor (NSWindow) -> Bool,
        responderRetainsFeedFocus: @escaping (NSResponder) -> Bool
    ) {
        self.questions = questions
        self.source = source
        self.status = status
        self.isRowSelected = isRowSelected
        self.onFocusRow = onFocusRow
        self.onActionRow = onActionRow
        self.onBlurRow = onBlurRow
        self.context = context
        self.onReply = onReply
        self.moveFocusToFeedHost = moveFocusToFeedHost
        self.responderRetainsFeedFocus = responderRetainsFeedFocus
    }

    /// Pure projections over the prompt set (answer composition,
    /// long-form layout, plan detection). The view owns the live
    /// `selections`/`freeTexts` state and passes them in per call.
    private var interview: WorkstreamQuestionInterview {
        WorkstreamQuestionInterview(
            questions: questions,
            source: source,
            context: context
        )
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if shouldRenderLongForm, let q = questions.first {
                longFormBlock(question: q)
            } else {
                ForEach(Array(questions.enumerated()), id: \.offset) { idx, q in
                    questionBlock(index: idx + 1, question: q)
                }
            }
            if shouldShowSkipInterviewCTA {
                HStack(spacing: 8) {
                    skipInterviewCTA
                    submitCTA
                }
            } else {
                submitCTA
            }
        }
        .onChange(of: isRowSelected) { _, selected in
            if !selected {
                clearCustomAnswerFocus()
            }
        }
    }

    private var shouldRenderLongForm: Bool {
        interview.shouldRenderLongForm
    }

    private var agentLabel: String {
        "\(source.rawValue.capitalized):"
    }

    /// Long-form rendering: single question with rich options. Each
    /// option becomes a tappable card with numbered index, title, and
    /// description. Selecting only updates local state; the Submit
    /// button sends the answer.
    @ViewBuilder
    private func longFormBlock(question: WorkstreamQuestionPrompt) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if !question.prompt.isEmpty {
                FeedLabeledTextRow(
                    label: agentLabel,
                    text: question.prompt,
                    labelColor: .secondary,
                    textColor: .primary.opacity(0.95)
                )
            }
            ForEach(Array(question.options.enumerated()), id: \.offset) { idx, option in
                longFormOptionCard(
                    questionId: question.id,
                    multi: question.multiSelect,
                    index: idx + 1,
                    option: option
                )
            }
            if status.isPending {
                longFormCustomAnswerCard(
                    questionId: question.id,
                    multi: question.multiSelect,
                    index: question.options.count + 1
                )
            }
        }
    }

    private func longFormOptionCard(
        questionId: String,
        multi: Bool,
        index: Int,
        option: WorkstreamQuestionOption
    ) -> some View {
        let selected = selections[questionId]?.contains(option.id) == true
        return Button {
            guard status.isPending else { return }
            onActionRow()
            clearCustomAnswerFocus()
            var current = selections[questionId] ?? []
            if multi {
                if current.contains(option.id) {
                    current.remove(option.id)
                } else {
                    current.insert(option.id)
                }
            } else {
                current = [option.id]
            }
            selections[questionId] = current
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Text("\(index)")
                    .font(.system(size: 11, weight: .bold).monospacedDigit())
                    .foregroundColor(selected ? .white : .secondary)
                    .frame(width: 20, height: 20)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(selected ? Color(red: 0.24, green: 0.48, blue: 0.88) : Color.primary.opacity(0.08))
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.label)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.primary)
                    if let description = option.description, !description.isEmpty {
                        Text(description)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer()
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(selected ? Color(red: 0.24, green: 0.48, blue: 0.88) : .secondary.opacity(0.45))
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(selected ? Color(red: 0.24, green: 0.48, blue: 0.88).opacity(0.14) : Color.primary.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(selected ? Color(red: 0.24, green: 0.48, blue: 0.88).opacity(0.55) : Color.clear, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!status.isPending)
    }

    private func longFormCustomAnswerCard(
        questionId: String,
        multi: Bool,
        index: Int
    ) -> some View {
        let customId = Self.customAnswerSelectionId
        let selected = selections[questionId]?.contains(customId) == true
        let focusKey = customAnswerFocusKey(questionId)
        let font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        return HStack(alignment: .top, spacing: 10) {
            Text("\(index)")
                .font(.system(size: 11, weight: .bold).monospacedDigit())
                .foregroundColor(selected ? .white : .secondary)
                .frame(width: 20, height: 20)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(selected ? Color(red: 0.24, green: 0.48, blue: 0.88) : Color.primary.opacity(0.08))
                )
            customAnswerField(
                text: customAnswerBinding(questionId: questionId, multi: multi),
                focusRequest: focusRequest(forCustomAnswerKey: focusKey),
                font: font,
                onFocus: {
                    onFocusRow()
                    selectCustomAnswer(questionId: questionId, multi: multi)
                },
                onBlur: onBlurRow
            )
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(selected ? Color(red: 0.24, green: 0.48, blue: 0.88) : .secondary.opacity(0.45))
                .padding(.leading, 8)
                .padding(.top, 3)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(selected ? Color(red: 0.24, green: 0.48, blue: 0.88).opacity(0.14) : Color.primary.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(selected ? Color(red: 0.24, green: 0.48, blue: 0.88).opacity(0.55) : Color.clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            guard status.isPending else { return }
            onFocusRow()
            selectCustomAnswer(questionId: questionId, multi: multi)
            requestCustomAnswerFocus(focusKey)
        }
        .feedIBeamCursorOnHover(enabled: status.isPending)
        .disabled(!status.isPending)
    }

    private func questionBlock(index: Int, question: WorkstreamQuestionPrompt) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .top, spacing: 5) {
                Text("\(index).")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundColor(.blue)
                Text(question.prompt)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.primary.opacity(0.95))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if question.multiSelect {
                HStack(spacing: 3) {
                    Image(systemName: "checklist")
                        .font(.system(size: 8, weight: .medium))
                    Text(String(localized: "feed.question.multiSelect", defaultValue: "Multi-select", bundle: .main))
                        .font(.system(size: 9, weight: .semibold))
                        .tracking(0.3)
                }
                .foregroundColor(.orange)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(Color.orange.opacity(0.18))
                )
            }
            if question.options.isEmpty {
                Text(String(localized: "feed.question.noOptions",
                            defaultValue: "Agent provided no options.", bundle: .main))
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            } else {
                WrapHStack(spacing: 6) {
                    ForEach(question.options, id: \.id) { option in
                        optionPill(questionId: question.id, option: option, multi: question.multiSelect)
                    }
                }
            }
            if status.isPending {
                freeFormField(questionId: question.id, multi: question.multiSelect)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
    }

    /// "Type something…" free-form text field — mirrors Claude's TUI
    /// option 4 (custom answer). When non-empty it wins over the
    /// preset option selection for that question on submit.
    private func freeFormField(questionId: String, multi: Bool) -> some View {
        let focusKey = customAnswerFocusKey(questionId)
        let font = NSFont.systemFont(ofSize: 11)
        return customAnswerField(
            text: customAnswerBinding(questionId: questionId, multi: multi),
            focusRequest: focusRequest(forCustomAnswerKey: focusKey),
            font: font,
            onFocus: {
                onFocusRow()
                selectCustomAnswer(questionId: questionId, multi: multi)
            },
            onBlur: onBlurRow
        )
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .stroke(Color.primary.opacity(0.10), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .feedIBeamCursorOnHover(enabled: status.isPending)
        .onTapGesture {
            guard status.isPending else { return }
            onFocusRow()
            selectCustomAnswer(questionId: questionId, multi: multi)
            requestCustomAnswerFocus(focusKey)
        }
    }

    private func customAnswerField(
        text: Binding<String>,
        focusRequest: Int?,
        font: NSFont,
        onFocus: @escaping () -> Void,
        onBlur: @escaping () -> Void
    ) -> some View {
        FeedInlineTextField(
            text: text,
            focusRequest: focusRequest,
            placeholder: String(localized: "feed.question.typeSomething",
                                defaultValue: "Type something...", bundle: .main),
            isEnabled: status.isPending,
            font: font,
            onFocus: onFocus,
            onBlur: onBlur,
            onSubmit: nil,
            moveFocusToFeedHost: moveFocusToFeedHost,
            responderRetainsFeedFocus: responderRetainsFeedFocus
        )
        .frame(
            maxWidth: .infinity,
            minHeight: FeedInlineTextEditorView.minimumHeight(for: font),
            alignment: .leading
        )
        .layoutPriority(1)
    }

    private func customAnswerBinding(questionId: String, multi: Bool) -> Binding<String> {
        Binding<String>(
            get: { freeTexts[questionId] ?? "" },
            set: { value in
                freeTexts[questionId] = value
                var current = selections[questionId] ?? []
                if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    current.remove(Self.customAnswerSelectionId)
                } else if multi {
                    current.insert(Self.customAnswerSelectionId)
                } else {
                    current = [Self.customAnswerSelectionId]
                }
                selections[questionId] = current
            }
        )
    }

    private func customAnswerFocusKey(_ questionId: String) -> String {
        "\(questionId)::custom"
    }

    private func focusRequest(forCustomAnswerKey focusKey: String) -> Int? {
        customAnswerFocusKey == focusKey ? customAnswerFocusRequest : nil
    }

    private func requestCustomAnswerFocus(_ focusKey: String) {
        customAnswerFocusKey = focusKey
        customAnswerFocusRequest += 1
    }

    private func selectCustomAnswer(questionId: String, multi: Bool) {
        var current = selections[questionId] ?? []
        if multi {
            current.insert(Self.customAnswerSelectionId)
        } else {
            current = [Self.customAnswerSelectionId]
        }
        selections[questionId] = current
    }

    private func clearCustomAnswerFocus() {
        customAnswerFocusKey = nil
    }

    private func optionPill(
        questionId: String,
        option: WorkstreamQuestionOption,
        multi: Bool
    ) -> some View {
        let selected = selections[questionId]?.contains(option.id) == true
        let leading: String? = multi
            ? (selected ? "checkmark.square.fill" : "square")
            : nil
        let selectedKind: FeedButton.Kind = multi ? .success : .primary
        return FeedButton(
            label: option.label,
            leadingIcon: leading,
            kind: selected ? selectedKind : .soft,
            size: .compact,
            dimmed: !status.isPending
        ) {
            guard status.isPending else { return }
            onActionRow()
            clearCustomAnswerFocus()
            var current = selections[questionId] ?? []
            if multi {
                if current.contains(option.id) { current.remove(option.id) }
                else { current.insert(option.id) }
            } else {
                current = [option.id]
            }
            selections[questionId] = current
        }
    }

    private var composedAnswers: [String] {
        interview.composedAnswers(selections: selections, freeTexts: freeTexts)
    }

    private var hasAnyAnswer: Bool {
        interview.hasAnyAnswer(selections: selections, freeTexts: freeTexts)
    }

    private var canSubmitEmptyAnswer: Bool {
        interview.canSubmitEmptyAnswer
    }

    private var shouldShowSkipInterviewCTA: Bool {
        status.isPending && interview.isPlanAskUserQuestion
    }

    private var submitCTA: some View {
        let isPending = status.isPending
        let enabled = isPending && (hasAnyAnswer || canSubmitEmptyAnswer)
        return FeedButton(
            label: isPending
                ? String(localized: "feed.question.submitAll",
                         defaultValue: "Submit All Answers", bundle: .main)
                : String(localized: "feed.badge.submitted",
                         defaultValue: "Submitted", bundle: .main),
            leadingIcon: isPending ? "checkmark.circle.fill" : "checkmark",
            kind: enabled ? .primary : (isPending ? .soft : .success),
            size: .medium,
            fullWidth: true,
            dimmed: !enabled
        ) {
            onActionRow()
            // Selections carry human-readable answer strings (one per
            // answered question) so the hook can feed them straight
            // back to the agent as the user's reply.
            onReply(composedAnswers)
        }
    }

    private var skipInterviewCTA: some View {
        FeedButton(
            label: String(localized: "feed.question.skipInterviewPlan",
                          defaultValue: "Skip + plan immediately", bundle: .main),
            leadingIcon: "forward.end.fill",
            kind: .soft,
            size: .medium,
            fullWidth: true
        ) {
            onActionRow()
            onReply([Self.skipInterviewAndPlanAnswer])
        }
    }
}
