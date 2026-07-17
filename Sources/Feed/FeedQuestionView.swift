import AppKit
import Bonsplit
import CMUXAgentLaunch
import CmuxFoundation
import Foundation
import SwiftUI

struct QuestionActionArea: View {
    let questions: [WorkstreamQuestionPrompt]
    let source: WorkstreamSource
    let status: WorkstreamStatus
    let isRowSelected: Bool
    let onFocusRow: () -> Void
    let onActionRow: () -> Void
    let onBlurRow: () -> Void
    let context: WorkstreamContext?
    let placement: FeedPlacement
    let focusScopeID: UUID
    let onReply: ([String]) -> Void

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
    @Environment(\.cmuxGlobalFontMagnificationPercent) private var globalFontPercent

    var body: some View {
        let _ = globalFontPercent
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
        // Long-form: single question whose options carry descriptions
        // (e.g. Claude's AskUserQuestion with `header` + per-option
        // detail). Multi-option list with a bigger rich-text card per
        // option, click-to-select.
        guard questions.count == 1, let q = questions.first else { return false }
        return q.options.contains { $0.description?.isEmpty == false }
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
                    .cmuxFont(size: 12, weight: .bold, monospacedDigit: true)
                    .foregroundColor(selected ? .white : .secondary)
                    .frame(width: 20, height: 20)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(selected ? Color(red: 0.24, green: 0.48, blue: 0.88) : Color.primary.opacity(0.08))
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.label)
                        .cmuxFont(size: 13, weight: .semibold)
                        .foregroundColor(.primary)
                    if let description = option.description, !description.isEmpty {
                        Text(description)
                            .cmuxFont(size: 12)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer()
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .cmuxFont(size: 12, weight: .medium)
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
        let font = GlobalFontMagnification.systemFont(ofSize: 13, weight: .semibold)
        return HStack(alignment: .top, spacing: 10) {
            Text("\(index)")
                .cmuxFont(size: 12, weight: .bold, monospacedDigit: true)
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
                .cmuxFont(size: 12, weight: .medium)
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
        .disabled(!status.isPending)
    }

    private func questionBlock(index: Int, question: WorkstreamQuestionPrompt) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .top, spacing: 5) {
                Text("\(index).")
                    .cmuxFont(size: 12, weight: .semibold, monospacedDigit: true)
                    .foregroundColor(.blue)
                Text(question.prompt)
                    .cmuxFont(size: 13, weight: .medium)
                    .foregroundColor(.primary.opacity(0.95))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if question.options.isEmpty {
                Text(String(localized: "feed.question.noOptions",
                            defaultValue: "Agent provided no options."))
                    .cmuxFont(size: 10)
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
        let font = GlobalFontMagnification.systemFont(ofSize: 12)
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
                                defaultValue: "Type something..."),
            isEnabled: status.isPending,
            font: font,
            placement: placement,
            focusScopeID: focusScopeID,
            onFocus: onFocus,
            onBlur: onBlur,
            onSubmit: nil
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

    /// One answer string per question: the user's free-form text if
    /// they typed any, otherwise the labels of the selected options
    /// joined by ", ". Questions with no answer are omitted entirely
    /// so the agent doesn't see "question 2: <empty>".
    private var composedAnswers: [String] {
        var out: [String] = []
        for q in questions {
            let freeText = (freeTexts[q.id] ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let ids = selections[q.id] ?? []
            if !freeText.isEmpty, ids.contains(Self.customAnswerSelectionId) {
                out.append(freeText)
                continue
            }
            guard !ids.isEmpty else { continue }
            let labels = q.options
                .filter { ids.contains($0.id) }
                .map(\.label)
            if !labels.isEmpty {
                out.append(labels.joined(separator: ", "))
            }
        }
        return out
    }

    private var hasAnyAnswer: Bool { !composedAnswers.isEmpty }

    private var canSubmitEmptyAnswer: Bool {
        !questions.isEmpty && questions.allSatisfy { $0.options.isEmpty }
    }

    private var shouldShowSkipInterviewCTA: Bool {
        status.isPending && isPlanAskUserQuestion
    }

    private var isPlanAskUserQuestion: Bool {
        guard source == .claude, let mode = context?.permissionMode else {
            return false
        }
        return mode.caseInsensitiveCompare("plan") == .orderedSame
    }

    private var submitCTA: some View {
        let isPending = status.isPending
        let enabled = isPending && (hasAnyAnswer || canSubmitEmptyAnswer)
        return FeedButton(
            label: isPending
                ? String(localized: "feed.question.submitAll",
                         defaultValue: "Submit All Answers")
                : String(localized: "feed.badge.submitted",
                         defaultValue: "Submitted"),
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
                          defaultValue: "Skip + plan immediately"),
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
