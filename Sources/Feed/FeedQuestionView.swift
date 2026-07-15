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
                    .cmuxFont(size: 11, weight: .bold, monospacedDigit: true)
                    .foregroundColor(selected ? .white : .secondary)
                    .frame(width: 20, height: 20)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(selected ? Color(red: 0.24, green: 0.48, blue: 0.88) : Color.primary.opacity(0.08))
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.label)
                        .cmuxFont(size: 12, weight: .semibold)
                        .foregroundColor(.primary)
                    if let description = option.description, !description.isEmpty {
                        Text(description)
                            .cmuxFont(size: 11)
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
        let font = GlobalFontMagnification.systemFont(ofSize: 12, weight: .semibold)
        return HStack(alignment: .top, spacing: 10) {
            Text("\(index)")
                .cmuxFont(size: 11, weight: .bold, monospacedDigit: true)
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
        .feedIBeamCursorOnHover(enabled: status.isPending)
        .disabled(!status.isPending)
    }

    private func questionBlock(index: Int, question: WorkstreamQuestionPrompt) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .top, spacing: 5) {
                Text("\(index).")
                    .cmuxFont(size: 11, weight: .semibold, monospacedDigit: true)
                    .foregroundColor(.blue)
                Text(question.prompt)
                    .cmuxFont(size: 11, weight: .medium)
                    .foregroundColor(.primary.opacity(0.95))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if question.multiSelect {
                HStack(spacing: 3) {
                    Image(systemName: "checklist")
                        .cmuxFont(size: 8, weight: .medium)
                    Text(String(localized: "feed.question.multiSelect", defaultValue: "Multi-select"))
                        .cmuxFont(size: 9, weight: .semibold)
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
        let font = GlobalFontMagnification.systemFont(ofSize: 11)
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
                                defaultValue: "Type something..."),
            isEnabled: status.isPending,
            font: font,
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
        guard source == .claude else { return false }
        if let mode = context?.permissionMode {
            return mode.caseInsensitiveCompare("plan") == .orderedSame
        }
        return questionTextLooksLikePlanInterview
    }

    private var questionTextLooksLikePlanInterview: Bool {
        let fragments: [String?] = questions.flatMap { q in
            let questionFragments: [String?] = [q.header, q.prompt]
            let optionFragments: [String?] = q.options.flatMap { option in
                [option.label, option.description]
            }
            return questionFragments + optionFragments
        }
        let text = ([context?.lastUserMessage, context?.assistantPreamble] + fragments)
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()
        return text.contains("plan mode")
            || text.contains("make a plan")
            || text.contains("plan-only")
            || text.contains("plan immediately")
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

private final class FeedInlinePassthroughLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

final class FeedInlineNativeTextView: NSTextView, FeedKeyboardFocusResponder {
    private static weak var activeEditor: FeedInlineNativeTextView?

    var onActivate: (() -> Void)?
    var onEscape: (() -> Void)?
    var onSubmit: (() -> Void)?

    static func blurActiveEditor() {
        guard let activeEditor else { return }
        guard let window = activeEditor.window else {
            if Self.activeEditor === activeEditor {
                Self.activeEditor = nil
            }
            return
        }
        guard window.firstResponder === activeEditor else {
            if Self.activeEditor === activeEditor {
                Self.activeEditor = nil
            }
            return
        }
#if DEBUG
        dlog("feed.editor.blurActive fr=\(feedDebugResponderSummary(window.firstResponder))")
#endif
        window.makeFirstResponder(nil)
    }

    override func mouseDown(with event: NSEvent) {
#if DEBUG
        dlog("feed.editor.mouseDown frBefore=\(feedDebugResponderSummary(window?.firstResponder))")
#endif
        onActivate?()
        super.mouseDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown, event.keyCode == 53 {
#if DEBUG
            dlog("feed.editor.escape fr=\(feedDebugResponderSummary(window?.firstResponder))")
#endif
            onEscape?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        let normalizedFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let shouldSubmit = (event.keyCode == 36 || event.keyCode == 76)
            && normalizedFlags.intersection([.shift, .option, .command, .control]).isEmpty
        if shouldSubmit, !hasMarkedText(), let onSubmit {
            onSubmit()
            return
        }
        super.keyDown(with: event)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .iBeam)
    }

    override func becomeFirstResponder() -> Bool {
        let didBecomeFirstResponder = super.becomeFirstResponder()
        if didBecomeFirstResponder {
            Self.activeEditor = self
            onActivate?()
        }
#if DEBUG
        dlog("feed.editor.become result=\(didBecomeFirstResponder ? 1 : 0) fr=\(feedDebugResponderSummary(window?.firstResponder))")
#endif
        return didBecomeFirstResponder
    }

    override func resignFirstResponder() -> Bool {
        let didResignFirstResponder = super.resignFirstResponder()
        if didResignFirstResponder, Self.activeEditor === self {
            Self.activeEditor = nil
        }
#if DEBUG
        dlog("feed.editor.resign result=\(didResignFirstResponder ? 1 : 0) fr=\(feedDebugResponderSummary(window?.firstResponder))")
#endif
        return didResignFirstResponder
    }
}

final class FeedInlineTextEditorView: NSView {
    private static let textInset = NSSize(width: 0, height: 1)

    let textView = FeedInlineNativeTextView(frame: .zero)
    private let placeholderField = FeedInlinePassthroughLabel(labelWithString: "")
    private var currentFont = GlobalFontMagnification.systemFont(ofSize: 11)

    static func minimumHeight(for font: NSFont) -> CGFloat {
        ceil(font.ascender - font.descender + font.leading) + textInset.height * 2
    }

    var placeholder: String = "" {
        didSet {
            guard placeholder != oldValue else { return }
            placeholderField.stringValue = placeholder
            updatePlaceholderVisibility()
        }
    }

    var isEnabled: Bool = true {
        didSet {
            guard isEnabled != oldValue else { return }
            textView.isEditable = isEnabled
            textView.isSelectable = isEnabled
            textView.textColor = isEnabled ? .labelColor : .disabledControlTextColor
            textView.insertionPointColor = .controlAccentColor
        }
    }

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.textContainerInset = Self.textInset
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        textView.minSize = .zero
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        addSubview(textView)

        placeholderField.textColor = .placeholderTextColor
        placeholderField.lineBreakMode = .byWordWrapping
        placeholderField.maximumNumberOfLines = 0
        addSubview(placeholderField)

        apply(font: currentFont, isEnabled: true)
        updatePlaceholderVisibility()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: fittingHeight())
    }

    override func mouseDown(with event: NSEvent) {
        _ = window?.makeFirstResponder(textView)
        super.mouseDown(with: event)
    }

    override func layout() {
        super.layout()
        let availableWidth = max(bounds.width, 1)
        let height = fittingHeight(for: availableWidth)
        textView.frame = NSRect(x: 0, y: 0, width: availableWidth, height: height)
        placeholderField.frame = NSRect(
            x: Self.textInset.width,
            y: Self.textInset.height,
            width: max(bounds.width - Self.textInset.width * 2, 1),
            height: Self.minimumHeight(for: currentFont)
        )
    }

    func apply(font: NSFont, isEnabled: Bool) {
        let fontChanged = currentFont != font || textView.font != font || placeholderField.font != font
        let enabledChanged = self.isEnabled != isEnabled

        if fontChanged {
            currentFont = font
            textView.font = font
            placeholderField.font = font
            textView.textColor = self.isEnabled ? .labelColor : .disabledControlTextColor
            textView.insertionPointColor = .controlAccentColor
        }
        if enabledChanged {
            self.isEnabled = isEnabled
        }
        if fontChanged || enabledChanged {
            refreshMetrics()
        }
    }

    func refreshMetrics() {
        updatePlaceholderVisibility()
        needsLayout = true
        invalidateIntrinsicContentSize()
        layoutSubtreeIfNeeded()
    }

    func focusIfNeeded() {
        guard let window, window.firstResponder !== textView else { return }
        window.makeFirstResponder(textView)
        let length = (textView.string as NSString).length
        textView.setSelectedRange(NSRange(location: length, length: 0))
    }

    func fittingHeight(for width: CGFloat) -> CGFloat {
        guard let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else {
            return Self.minimumHeight(for: currentFont)
        }
        let availableWidth = max(width - Self.textInset.width * 2, 1)
        textContainer.containerSize = NSSize(
            width: availableWidth,
            height: CGFloat.greatestFiniteMagnitude
        )
        layoutManager.ensureLayout(for: textContainer)
        let usedRect = layoutManager.usedRect(for: textContainer)
        let extraLineHeight = layoutManager.extraLineFragmentTextContainer == textContainer
            ? layoutManager.extraLineFragmentRect.height
            : 0
        let lineHeight = ceil(currentFont.ascender - currentFont.descender + currentFont.leading)
        let contentHeight = max(lineHeight, ceil(usedRect.height + extraLineHeight))
        return max(
            Self.minimumHeight(for: currentFont),
            ceil(contentHeight + Self.textInset.height * 2)
        )
    }

    private func updateTextViewLayout() {
        let availableWidth = max(bounds.width, 1)
        let height = fittingHeight(for: availableWidth)
        textView.frame = NSRect(x: 0, y: 0, width: availableWidth, height: height)
    }

    private func fittingHeight() -> CGFloat {
        guard bounds.width > 1 else {
            return Self.minimumHeight(for: currentFont)
        }
        let availableWidth = max(bounds.width, 1)
        return fittingHeight(for: availableWidth)
    }

    private func updatePlaceholderVisibility() {
        placeholderField.isHidden = !textView.string.isEmpty
    }
}

struct FeedInlineTextField: NSViewRepresentable {
    @Binding var text: String

    let focusRequest: Int?
    let placeholder: String
    let isEnabled: Bool
    let font: NSFont
    let onFocus: () -> Void
    let onBlur: () -> Void
    let onSubmit: (() -> Void)?

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: FeedInlineTextField
        var isProgrammaticMutation = false
        weak var view: FeedInlineTextEditorView?
        var lastAppliedFocusRequest: Int?

        init(parent: FeedInlineTextField) {
            self.parent = parent
            self.lastAppliedFocusRequest = parent.focusRequest
        }

        func activateField() {
#if DEBUG
            dlog("feed.editor.activateField")
#endif
            parent.onFocus()
        }

        func blurField() {
            guard let view, let window = view.window, window.firstResponder === view.textView else {
                return
            }
#if DEBUG
            dlog("feed.editor.blurField frBefore=\(feedDebugResponderSummary(window.firstResponder))")
#endif
            Task { @MainActor in
                if AppDelegate.shared?.focusRightSidebarInActiveMainWindow(
                    mode: .feed,
                    focusFirstItem: false,
                    preferredWindow: window
                ) != true {
                    window.makeFirstResponder(nil)
                }
            }
        }

        func textDidBeginEditing(_ notification: Notification) {
            activateField()
        }

        func textDidChange(_ notification: Notification) {
            guard !isProgrammaticMutation else { return }
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            view?.refreshMetrics()
        }

        func textDidEndEditing(_ notification: Notification) {
            if !isProgrammaticMutation, let textView = notification.object as? NSTextView {
                parent.text = textView.string
            }
            guard let window = view?.window else {
                parent.onBlur()
                return
            }
            let responder = window.firstResponder
            if !(responder is FeedKeyboardFocusView) && !(responder is FeedInlineNativeTextView) {
                parent.onBlur()
            }
        }

    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> FeedInlineTextEditorView {
        let view = FeedInlineTextEditorView(frame: .zero)
        view.textView.delegate = context.coordinator
        view.textView.string = text
        view.textView.onActivate = { [weak coordinator = context.coordinator] in
            coordinator?.activateField()
        }
        view.textView.onEscape = { [weak coordinator = context.coordinator] in
            coordinator?.blurField()
        }
        view.textView.onSubmit = onSubmit
        configure(view)
        context.coordinator.view = view
        return view
    }

    func updateNSView(_ nsView: FeedInlineTextEditorView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.view = nsView
        nsView.textView.onActivate = { [weak coordinator = context.coordinator] in
            coordinator?.activateField()
        }
        nsView.textView.onEscape = { [weak coordinator = context.coordinator] in
            coordinator?.blurField()
        }
        nsView.textView.onSubmit = onSubmit
        configure(nsView)

        if nsView.textView.string != text, !nsView.textView.hasMarkedText() {
            context.coordinator.isProgrammaticMutation = true
            nsView.textView.string = text
            context.coordinator.isProgrammaticMutation = false
            nsView.refreshMetrics()
        }

        guard let window = nsView.window else { return }
        let isFirstResponder = window.firstResponder === nsView.textView
        if let focusRequest,
           focusRequest != context.coordinator.lastAppliedFocusRequest {
            context.coordinator.lastAppliedFocusRequest = focusRequest
            if isEnabled {
                nsView.focusIfNeeded()
            } else if isFirstResponder {
                moveFocusToFeedHost(in: window)
            }
        } else if focusRequest == nil {
            context.coordinator.lastAppliedFocusRequest = nil
            if !isEnabled, isFirstResponder {
                moveFocusToFeedHost(in: window)
            }
        } else if !isEnabled, isFirstResponder {
            moveFocusToFeedHost(in: window)
        }
    }

    private func moveFocusToFeedHost(in window: NSWindow) {
        if AppDelegate.shared?.focusRightSidebarInActiveMainWindow(
            mode: .feed,
            focusFirstItem: false,
            preferredWindow: window
        ) == true {
            return
        }
        window.makeFirstResponder(nil)
    }

    private func configure(_ view: FeedInlineTextEditorView) {
        view.placeholder = placeholder
        view.apply(font: font, isEnabled: isEnabled)
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: FeedInlineTextEditorView,
        context: Context
    ) -> CGSize? {
        nil
    }

    static func dismantleNSView(_ nsView: FeedInlineTextEditorView, coordinator: Coordinator) {
        nsView.textView.delegate = nil
        nsView.textView.onActivate = nil
        nsView.textView.onEscape = nil
        nsView.textView.onSubmit = nil
    }
}

private struct FeedHoverCursorModifier: ViewModifier {
    let enabled: Bool
    let cursor: NSCursor

    @State private var cursorPushed = false

    func body(content: Content) -> some View {
        content
            .onHover { hovering in
                if hovering, enabled {
                    pushIfNeeded()
                } else {
                    popIfNeeded()
                }
            }
            .onDisappear {
                popIfNeeded()
            }
    }

    private func pushIfNeeded() {
        guard !cursorPushed else { return }
        cursor.push()
        cursorPushed = true
    }

    private func popIfNeeded() {
        guard cursorPushed else { return }
        NSCursor.pop()
        cursorPushed = false
    }
}

extension View {
    func feedIBeamCursorOnHover(enabled: Bool) -> some View {
        modifier(FeedHoverCursorModifier(enabled: enabled, cursor: .iBeam))
    }
}

/// Minimal wrapping HStack that flows its children into multiple rows.
private struct WrapHStack<Content: View>: View {
    let spacing: CGFloat
    let content: () -> Content

    init(spacing: CGFloat = 4, @ViewBuilder content: @escaping () -> Content) {
        self.spacing = spacing
        self.content = content
    }

    var body: some View {
        FlowLayout(spacing: spacing) {
            content()
        }
    }
}

private struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var currentX: CGFloat = 0
        var currentRowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var totalWidth: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if currentX + size.width > maxWidth && currentX > 0 {
                totalHeight += currentRowHeight + spacing
                totalWidth = max(totalWidth, currentX - spacing)
                currentX = 0
                currentRowHeight = 0
            }
            currentX += size.width + spacing
            currentRowHeight = max(currentRowHeight, size.height)
        }
        totalHeight += currentRowHeight
        totalWidth = max(totalWidth, currentX - spacing)
        return CGSize(width: totalWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x: CGFloat = bounds.minX
        var y: CGFloat = bounds.minY
        var rowHeight: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX && x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            sub.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/// Renders a Stop event (Claude finished a turn and is waiting for
/// the next user prompt). Shows a text field + Send button that
/// types the reply into the agent's terminal surface and presses
/// Return — so the user can reply without switching focus.
