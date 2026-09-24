#if os(iOS)
import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

/// Store-free action closures the Feed rows invoke. Rows never retain the
/// shell store (SwiftUI list-boundary rule); ``AgentFeedStoreView`` owns the
/// store and builds one of these per render.
struct AgentFeedActions {
    var permissionReply: @MainActor (MobileAgentFeedItem, _ mode: String) -> Void = { _, _ in }
    var questionReply: @MainActor (MobileAgentFeedItem, _ selections: [String]) -> Void = { _, _ in }
    var exitPlanReply: @MainActor (MobileAgentFeedItem, _ mode: String, _ feedback: String?) -> Void = { _, _, _ in }
    var terminalReply: @MainActor (MobileAgentFeedItem, _ text: String) -> Void = { _, _ in }
    /// Opens the X-style reply composer sheet; rows never host a keyboard.
    var beginCompose: @MainActor (MobileAgentFeedItem, AgentFeedComposeContext.Kind) -> Void = { _, _ in }
    /// Opens the event's current tab when available, or its workspace when it
    /// has no live tab target. The menu intentionally presents one action for
    /// both destinations.
    var openDestination: @MainActor (MobileAgentFeedItem) -> Void = { _ in }
    var viewFullText: @MainActor (MobileAgentFeedItem) -> Void = { _ in }
    var loadFullText: @MainActor (MobileAgentFeedItem) async throws -> String = { _ in
        throw URLError(.unsupportedURL)
    }
    /// Local needs-input triage — the Feed's mark-read/unread analogue.
    var setNeedsInput: @MainActor (MobileAgentFeedItem, Bool) -> Void = { _, _ in }
    var refresh: @MainActor () async -> Void = {}
}

/// The one visual family every Feed action shares: option-bar-shaped
/// rounded rects. Primary fills with the accent, neutral with a quiet
/// fill, destructive with a red tint — no stock bordered styles, no
/// bare red-on-gray labels.
enum AgentFeedActionRole {
    case primary
    case neutral
    case destructive

    var fill: Color {
        switch self {
        case .primary: return Color.accentColor
        case .neutral: return Color.secondary.opacity(0.15)
        case .destructive: return Color.red.opacity(0.16)
        }
    }

    var label: Color {
        switch self {
        case .primary: return .white
        case .neutral: return .primary
        case .destructive: return .red
        }
    }
}

struct AgentFeedActionButton: View {
    let title: String
    let role: AgentFeedActionRole
    let action: @MainActor () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 10).fill(role.fill))
                .foregroundStyle(role.label)
        }
        .buttonStyle(.plain)
    }
}

/// The overflow menu chip, matching the action buttons' height and fill at
/// full label strength (never dimmed).
struct AgentFeedOverflowMenuLabel: View {
    var body: some View {
        Image(systemName: "ellipsis")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.primary)
            .frame(width: 44)
            .padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.15)))
    }
}

/// One X-style full-width Feed row: avatar gutter, author line, inline agent
/// output, and — for respondable rows — the decision controls themselves.
struct AgentFeedRow: View, Equatable {
    let model: AgentFeedRowModel
    let isReplyPending: Bool
    let now: Date
    /// CMUX Labs quote treatment: iMessage-style bubbles instead of the
    /// leading-bar quote.
    var bubbleQuotes = false
    let actions: AgentFeedActions

    /// Rows re-render only when their item, pending flag, time reference, or
    /// quote treatment changes; `actions` closures are excluded by design.
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.model == rhs.model
            && lhs.isReplyPending == rhs.isReplyPending
            && lhs.now == rhs.now
            && lhs.bubbleQuotes == rhs.bubbleQuotes
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            avatar
            VStack(alignment: .leading, spacing: 6) {
                authorLine
                if let quoted = model.presentation.quotedUserMessage {
                    quotedMessage(quoted)
                }
                if let output = model.presentation.outputText {
                    AgentFeedInlineText(
                        text: output,
                        hasMoreText: model.item.fullTextTruncated,
                        lineLimit: 8,
                        itemID: model.item.itemID,
                        open: { actions.viewFullText(model.item) }
                    )
                }
                if let toolLine = model.presentation.toolLine {
                    if model.item.kind == .toolResult {
                        AgentFeedInlineText(
                            text: toolLine,
                            hasMoreText: model.item.fullTextTruncated
                                || model.item.fullTextPreview.map { $0 != toolLine } == true,
                            lineLimit: 2,
                            itemID: model.item.itemID,
                            textStyle: .caption1,
                            monospaced: true,
                            color: model.item.toolResultIsError ? .systemRed : .secondaryLabel,
                            open: { actions.viewFullText(model.item) }
                        )
                    } else {
                        Text(toolLine)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                if let resolution = model.presentation.resolutionLabel {
                    resolutionLine(resolution)
                } else if model.item.needsInput {
                    AgentFeedDecisionControls(
                        item: model.item,
                        isReplyPending: isReplyPending,
                        actions: actions
                    )
                } else if model.item.supportsTerminalReply, model.item.kind == .stop {
                    if let reply = model.item.userReply {
                        userReplyMarker(
                            reply: reply,
                            reference: model.presentation.replyReferenceSnippet
                        )
                    }
                    replyButton
                }
            }
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .contain)
        .contextMenu {
            if model.item.connectionStatus == .connected, model.item.remoteWorkspaceID != nil {
                Button {
                    actions.openDestination(model.item)
                } label: {
                    Label(String(localized: "mobile.agentFeed.open", defaultValue: "Open", bundle: .module),
                          systemImage: "rectangle.stack")
                }
            }
        }
    }

    private var avatar: some View {
        ZStack {
            Circle()
                .fill(Color.secondary.opacity(0.12))
                .frame(width: 40, height: 40)
            if model.presentation.authorIsUser {
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
            } else {
                TaskTemplateIcon(value: model.presentation.authorIconValue, size: 22)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if model.item.effectiveNeedsInput {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 10, height: 10)
                    .overlay(Circle().stroke(PlatformPalette.systemBackground, lineWidth: 2))
            }
        }
        .accessibilityHidden(true)
    }

    private var authorLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(model.presentation.authorName)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .layoutPriority(2)
            Text(model.presentation.headline)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(model.compactTimeLabel(now: now))
                .font(.caption)
                .foregroundStyle(.tertiary)
                .layoutPriority(2)
        }
    }

    @ViewBuilder
    private func quotedMessage(_ message: String) -> some View {
        if bubbleQuotes {
            bubbleQuote(message, lineLimit: 3)
        } else {
            barQuote(message)
        }
    }

    /// An iMessage-style quoted message: secondary text inside an outlined
    /// bubble whose tail points back at the avatar gutter.
    private func bubbleQuote(_ message: String, lineLimit: Int) -> some View {
        AgentFeedMarkdownText(
            markdown: message,
            font: .footnote,
            color: .secondary,
            lineLimit: lineLimit
        )
        .fixedSize(horizontal: false, vertical: true)
        .padding(.leading, 12 + AgentFeedBubbleShape.tailWidth)
        .padding(.trailing, 12)
        .padding(.vertical, 7)
        .overlay(
            AgentFeedBubbleShape()
                .stroke(Color.secondary.opacity(0.45), lineWidth: 1)
        )
    }

    private func barQuote(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(Color.secondary.opacity(0.35))
                .frame(width: 3)
            AgentFeedMarkdownText(
                markdown: message,
                font: .footnote,
                color: .secondary,
                lineLimit: 3
            )
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    /// The reply affordance under a finished turn follows social-feed action
    /// bars: a quiet secondary-colored outline icon and label that sit at
    /// text scale, so blue stays reserved for links like See more. The hit
    /// area extends past the visible label to a 44-point target without
    /// adding layout height to the row.
    private var replyButton: some View {
        Button {
            actions.beginCompose(model.item, .terminalReply)
        } label: {
            HStack(alignment: .center, spacing: 5) {
                Group {
                    if isReplyPending {
                        ProgressView()
                            .controlSize(.mini)
                    } else {
                        Image(systemName: model.item.userReply == nil
                            ? "arrowshape.turn.up.left"
                            : "checkmark")
                            .imageScale(.small)
                            .fontWeight(.medium)
                    }
                }
                .frame(width: 16, height: 16)
                .accessibilityHidden(true)
                Text(replyButtonTitle)
            }
            .font(.footnote.weight(.medium))
            .foregroundStyle(.secondary)
            .contentShape(Rectangle().inset(by: -13))
        }
        .buttonStyle(.plain)
        .disabled(isReplyPending || model.item.userReply != nil)
        .padding(.top, 2)
        .accessibilityIdentifier("MobileAgentFeedReplyButton")
    }

    private var replyButtonTitle: String {
        if isReplyPending {
            return String(
                localized: "mobile.agentFeed.reply.sending",
                defaultValue: "Sending…",
                bundle: .module
            )
        }
        if model.item.userReply != nil {
            return String(
                localized: "mobile.agentFeed.reply.replied",
                defaultValue: "Replied",
                bundle: .module
            )
        }
        return String(
            localized: "mobile.agentFeed.compose.reply",
            defaultValue: "Reply",
            bundle: .module
        )
    }

    /// The user's recorded reply, quote-referencing the message it answered.
    @ViewBuilder
    private func userReplyMarker(reply: String, reference: String?) -> some View {
        if bubbleQuotes {
            bubbleReplyMarker(reply: reply, reference: reference)
        } else {
            barReplyMarker(reply: reply, reference: reference)
        }
    }

    /// iMessage inline-reply layout: the answered message as an outlined
    /// quote bubble, the sender name, then the reply in a filled bubble.
    private func bubbleReplyMarker(reply: String, reference: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let reference {
                bubbleQuote(reference, lineLimit: 2)
                    .padding(.bottom, 2)
            }
            Text(String(
                localized: "mobile.agentFeed.reply.youLabel",
                defaultValue: "You",
                bundle: .module
            ))
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.leading, AgentFeedBubbleShape.tailWidth + 12)
            AgentFeedMarkdownText(markdown: reply, font: .subheadline)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 12 + AgentFeedBubbleShape.tailWidth)
                .padding(.trailing, 12)
                .padding(.vertical, 8)
                .background(
                    AgentFeedBubbleShape()
                        .fill(Color(uiColor: .systemGray5))
                )
        }
        .padding(.top, 2)
    }

    private func barReplyMarker(reply: String, reference: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let reference {
                HStack(spacing: 5) {
                    Image(systemName: "arrowshape.turn.up.left")
                        .font(.caption2)
                    Text(String(
                        localized: "mobile.agentFeed.reply.referenceFormat",
                        defaultValue: "Replying to “\(reference)”",
                        bundle: .module
                    ))
                    .font(.caption)
                    .lineLimit(1)
                }
                .foregroundStyle(.tertiary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(String(
                    localized: "mobile.agentFeed.reply.youLabel",
                    defaultValue: "You",
                    bundle: .module
                ))
                .font(.footnote.weight(.semibold))
                AgentFeedMarkdownText(markdown: reply, font: .footnote)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.accentColor.opacity(0.12))
            )
        }
        .padding(.top, 2)
    }

    private func resolutionLine(_ label: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: resolutionSymbolName)
                .font(.caption2)
            Text(label)
                .font(.footnote.weight(.medium))
                .lineLimit(2)
        }
        .foregroundStyle(.secondary)
        .padding(.top, 2)
    }

    private var resolutionSymbolName: String {
        switch model.item.status {
        case .expired:
            return "hourglass"
        case .resolved(let decision):
            return decision.mode == "deny" ? "xmark.circle" : "checkmark.circle"
        case .pending, .telemetry:
            return "checkmark.circle"
        }
    }
}

/// The respondable controls of one pending actionable row.
private struct AgentFeedDecisionControls: View {
    let item: MobileAgentFeedItem
    let isReplyPending: Bool
    let actions: AgentFeedActions

    var body: some View {
        Group {
            switch item.kind {
            case .permissionRequest:
                permissionControls
            case .exitPlan:
                AgentFeedExitPlanControls(
                    item: item,
                    isReplyPending: isReplyPending,
                    actions: actions
                )
            case .question:
                AgentFeedQuestionControls(
                    item: item,
                    isReplyPending: isReplyPending,
                    actions: actions
                )
            case .toolUse, .toolResult, .userPrompt, .assistantMessage, .stop, .todos, .unsupported:
                EmptyView()
            }
        }
        .disabled(isReplyPending)
        .opacity(isReplyPending ? 0.55 : 1)
        .padding(.top, 4)
    }

    private var permissionControls: some View {
        HStack(spacing: 8) {
            AgentFeedActionButton(
                title: String(
                    localized: "mobile.agentFeed.permission.allow",
                    defaultValue: "Allow",
                    bundle: .module
                ),
                role: .primary
            ) {
                actions.permissionReply(item, "once")
            }

            AgentFeedActionButton(
                title: String(
                    localized: "mobile.agentFeed.permission.always",
                    defaultValue: "Always",
                    bundle: .module
                ),
                role: .neutral
            ) {
                actions.permissionReply(item, "always")
            }

            AgentFeedActionButton(
                title: String(
                    localized: "mobile.agentFeed.permission.deny",
                    defaultValue: "Deny",
                    bundle: .module
                ),
                role: .destructive
            ) {
                actions.permissionReply(item, "deny")
            }

            Menu {
                Button {
                    actions.permissionReply(item, "all")
                } label: {
                    Label(
                        String(
                            localized: "mobile.agentFeed.permission.allowAll",
                            defaultValue: "Allow All This Session",
                            bundle: .module
                        ),
                        systemImage: "checkmark.circle.badge.questionmark"
                    )
                }
                Button {
                    actions.permissionReply(item, "bypass")
                } label: {
                    Label(
                        String(
                            localized: "mobile.agentFeed.permission.bypass",
                            defaultValue: "Bypass Permissions",
                            bundle: .module
                        ),
                        systemImage: "bolt.badge.checkmark"
                    )
                }
            } label: {
                AgentFeedOverflowMenuLabel()
            }
            .accessibilityLabel(String(
                localized: "mobile.agentFeed.permission.moreOptions",
                defaultValue: "More permission options",
                bundle: .module
            ))
        }
    }
}

/// Approve / Revise… / Deny for a pending exit-plan row. Approve sends the
/// agent's preselected mode; the menu exposes every mode; Revise reveals an
/// inline feedback field.
private struct AgentFeedExitPlanControls: View {
    let item: MobileAgentFeedItem
    let isReplyPending: Bool
    let actions: AgentFeedActions

    private var approveMode: String { item.defaultExitPlanMode ?? "manual" }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                AgentFeedActionButton(
                    title: String(
                        localized: "mobile.agentFeed.exitPlan.approve",
                        defaultValue: "Approve",
                        bundle: .module
                    ),
                    role: .primary
                ) {
                    actions.exitPlanReply(item, approveMode, nil)
                }

                AgentFeedActionButton(
                    title: String(
                        localized: "mobile.agentFeed.exitPlan.revise",
                        defaultValue: "Revise…",
                        bundle: .module
                    ),
                    role: .neutral
                ) {
                    actions.beginCompose(item, .planRevise)
                }

                AgentFeedActionButton(
                    title: String(
                        localized: "mobile.agentFeed.permission.deny",
                        defaultValue: "Deny",
                        bundle: .module
                    ),
                    role: .destructive
                ) {
                    actions.exitPlanReply(item, "deny", nil)
                }

                Menu {
                    ForEach(AgentFeedExitPlanControls.approveModes, id: \.mode) { entry in
                        Button {
                            actions.exitPlanReply(item, entry.mode, nil)
                        } label: {
                            Text(entry.label)
                        }
                    }
                } label: {
                    AgentFeedOverflowMenuLabel()
                }
                .accessibilityLabel(String(
                    localized: "mobile.agentFeed.exitPlan.moreModes",
                    defaultValue: "More approval modes",
                    bundle: .module
                ))
            }
        }
    }

    static var approveModes: [(mode: String, label: String)] {
        [
            (
                "manual",
                String(
                    localized: "mobile.agentFeed.exitPlan.mode.manual",
                    defaultValue: "Approve (manual edits)",
                    bundle: .module
                )
            ),
            (
                "autoAccept",
                String(
                    localized: "mobile.agentFeed.exitPlan.mode.autoAccept",
                    defaultValue: "Approve, auto-accept edits",
                    bundle: .module
                )
            ),
            (
                "bypassPermissions",
                String(
                    localized: "mobile.agentFeed.exitPlan.mode.bypassPermissions",
                    defaultValue: "Approve, bypass permissions",
                    bundle: .module
                )
            ),
            (
                "ultraplan",
                String(
                    localized: "mobile.agentFeed.exitPlan.mode.ultraplan",
                    defaultValue: "Approve as ultraplan",
                    bundle: .module
                )
            ),
        ]
    }
}

/// Option cards for one or more questions. Multi-question rounds use a
/// swipeable page at a time and submit one ordered, human-readable answer per
/// page, mirroring Claude's desktop question flow.
private struct AgentFeedQuestionControls: View {
    let item: MobileAgentFeedItem
    let isReplyPending: Bool
    let actions: AgentFeedActions
    @State private var selectedOptionIDsByQuestion: [String: Set<String>] = [:]
    @State private var customTextByQuestion: [String: String] = [:]
    @State private var pageIndex = 0
    @State private var editingCustomAnswerForQuestionID: String?
    @FocusState private var focusedCustomAnswerQuestionID: String?

    private var questions: [MobileAgentFeedQuestion] {
        if item.questions.isEmpty {
            return [MobileAgentFeedQuestion(id: "q0", prompt: "")]
        }
        return item.questions
    }

    private var isPaged: Bool { questions.count > 1 }

    private var canSubmitAll: Bool {
        AgentFeedQuestionAnswerDraft.answers(
            for: questions,
            drafts: drafts
        ) != nil
    }

    private var drafts: [String: AgentFeedQuestionAnswerDraft] {
        Dictionary(uniqueKeysWithValues: questions.map { question in
            (
                question.id,
                AgentFeedQuestionAnswerDraft(
                    selectedOptionIDs: selectedOptionIDsByQuestion[question.id] ?? [],
                    customText: customTextByQuestion[question.id] ?? ""
                )
            )
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isPaged {
                pagerHeader
                TabView(selection: $pageIndex) {
                    ForEach(Array(questions.enumerated()), id: \.element.id) { index, question in
                        questionPage(question, index: index)
                            .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .frame(minHeight: 212)
                .animation(.snappy, value: pageIndex)
                pagerFooter
            } else if let question = questions.first {
                questionPage(question, index: 0)
                submitButton(title: String(
                    localized: "mobile.agentFeed.question.send",
                    defaultValue: "Send",
                    bundle: .module
                ))
            }
        }
        .disabled(isReplyPending)
        .onAppear {
            pageIndex = min(pageIndex, max(questions.count - 1, 0))
        }
        .onChange(of: item.id) { _, _ in
            pageIndex = 0
            selectedOptionIDsByQuestion = [:]
            customTextByQuestion = [:]
            editingCustomAnswerForQuestionID = nil
        }
    }

    private var pagerHeader: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text(String(
                    format: L10n.string(
                        "mobile.agentFeed.question.progress",
                        defaultValue: "Question %lld of %lld",
                        bundle: .module
                    ),
                    Int64(pageIndex + 1),
                    Int64(questions.count)
                ))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text(String(
                    format: L10n.string(
                        "mobile.agentFeed.question.answered",
                        defaultValue: "%lld answered",
                        bundle: .module
                    ),
                    Int64(answeredQuestionCount)
                ))
                .font(.caption)
                .foregroundStyle(.tertiary)
            }
            HStack(spacing: 5) {
                ForEach(questions.indices, id: \.self) { index in
                    Button {
                        withAnimation(.snappy) { pageIndex = index }
                    } label: {
                        Capsule()
                            .fill(index == pageIndex ? Color.accentColor : Color.secondary.opacity(0.22))
                            .frame(maxWidth: index == pageIndex ? 26 : 8, minHeight: 6, maxHeight: 6)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(String(
                        format: L10n.string(
                            "mobile.agentFeed.question.pageLabel",
                            defaultValue: "Question %lld",
                            bundle: .module
                        ),
                        Int64(index + 1)
                    ))
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var pagerFooter: some View {
        HStack(spacing: 8) {
            if pageIndex > 0 {
                Button {
                    withAnimation(.snappy) { pageIndex -= 1 }
                } label: {
                    Label(String(
                        localized: "mobile.agentFeed.question.previous",
                        defaultValue: "Previous",
                        bundle: .module
                    ), systemImage: "chevron.left")
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            if pageIndex < questions.count - 1 {
                Button {
                    withAnimation(.snappy) { pageIndex += 1 }
                } label: {
                    Label(String(
                        localized: "mobile.agentFeed.question.next",
                        defaultValue: "Next",
                        bundle: .module
                    ), systemImage: "chevron.right")
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!hasAnswer(for: questions[pageIndex]))
            } else {
                submitButton(title: String(
                    localized: "mobile.agentFeed.question.submitAll",
                    defaultValue: "Submit all answers",
                    bundle: .module
                ))
            }
        }
    }

    private var answeredQuestionCount: Int {
        questions.reduce(into: 0) { count, question in
            if hasAnswer(for: question) { count += 1 }
        }
    }

    @ViewBuilder
    private func questionPage(_ question: MobileAgentFeedQuestion, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            if let header = question.header, !header.isEmpty {
                Text(header)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            if !question.prompt.isEmpty {
                AgentFeedMarkdownText(markdown: question.prompt,
                                      font: .subheadline.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if question.multiSelect {
                Label(String(
                    localized: "mobile.agentFeed.question.multiSelect",
                    defaultValue: "Select all that apply",
                    bundle: .module
                ), systemImage: "checklist")
                .font(.caption.weight(.medium))
                .foregroundStyle(.orange)
            }
            ForEach(question.options, id: \.id) { option in
                optionChip(option, question: question)
            }
            customAnswerControl(for: question)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 1)
        .padding(.vertical, 2)
        .accessibilityIdentifier("MobileAgentFeedQuestionPage-\(index + 1)")
    }

    private func submitButton(title: String) -> some View {
        Button {
            guard let answers = AgentFeedQuestionAnswerDraft.answers(for: questions, drafts: drafts) else { return }
            actions.questionReply(item, answers)
        } label: {
            Text(title)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
        .disabled(!canSubmitAll || isReplyPending)
        .accessibilityIdentifier("MobileAgentFeedQuestionSubmit")
    }

    private func hasAnswer(for question: MobileAgentFeedQuestion) -> Bool {
        (drafts[question.id] ?? AgentFeedQuestionAnswerDraft()).hasAnswer
    }

    private func optionChip(
        _ option: MobileAgentFeedQuestionOption,
        question: MobileAgentFeedQuestion
    ) -> some View {
        let isSelected = selectedOptionIDsByQuestion[question.id]?.contains(option.id) == true
        return Button {
            var selected = selectedOptionIDsByQuestion[question.id] ?? []
            if question.multiSelect {
                if isSelected { selected.remove(option.id) } else { selected.insert(option.id) }
            } else {
                selected = [option.id]
            }
            selectedOptionIDsByQuestion[question.id] = selected
            customTextByQuestion[question.id] = ""
        } label: {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    AgentFeedMarkdownText(markdown: option.label,
                                          font: .subheadline.weight(.medium))
                        .multilineTextAlignment(.leading)
                    if let description = option.description, !description.isEmpty {
                        AgentFeedMarkdownText(markdown: description,
                                              font: .caption,
                                              color: .secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 4)
                Image(systemName: question.multiSelect
                    ? (isSelected ? "checkmark.square.fill" : "square")
                    : (isSelected ? "checkmark.circle.fill" : "circle"))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary.opacity(0.55))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 10).fill(
                    isSelected ? Color.accentColor.opacity(0.16) : Color.secondary.opacity(0.12)
                )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isSelected ? Color.accentColor.opacity(0.55) : .clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("MobileAgentFeedQuestionOption-\(question.id)-\(option.id)")
    }

    @ViewBuilder
    private func customAnswerControl(for question: MobileAgentFeedQuestion) -> some View {
        let isEditing = editingCustomAnswerForQuestionID == question.id
        if isEditing || question.options.isEmpty {
            TextField(
                String(
                    localized: "mobile.agentFeed.question.otherPlaceholder",
                    defaultValue: "Your answer",
                    bundle: .module
                ),
                text: Binding(
                    get: { customTextByQuestion[question.id] ?? "" },
                    set: {
                        customTextByQuestion[question.id] = $0
                        selectedOptionIDsByQuestion[question.id] = []
                    }
                ),
                axis: .vertical
            )
            .lineLimit(2...5)
            .focused($focusedCustomAnswerQuestionID, equals: question.id)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.10)))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.28), lineWidth: 1))
            .onAppear {
                if isEditing { focusedCustomAnswerQuestionID = question.id }
            }
        } else {
            Button {
                editingCustomAnswerForQuestionID = question.id
                focusedCustomAnswerQuestionID = question.id
            } label: {
                Label(String(
                    localized: "mobile.agentFeed.question.other",
                    defaultValue: "Other…",
                    bundle: .module
                ), systemImage: "pencil")
                .font(.subheadline.weight(.medium))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.secondary.opacity(0.35)))
            }
            .buttonStyle(.plain)
        }
    }
}

#endif
