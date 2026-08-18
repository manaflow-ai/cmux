#if os(iOS)
import CmuxMobileShellModel
import SwiftUI

/// Store-free action closures the Feed rows invoke. Rows never retain the
/// shell store (SwiftUI list-boundary rule); ``AgentFeedStoreView`` owns the
/// store and builds one of these per render.
struct AgentFeedActions {
    var permissionReply: @MainActor (MobileAgentFeedItem, _ mode: String) -> Void = { _, _ in }
    var questionReply: @MainActor (MobileAgentFeedItem, _ selections: [String]) -> Void = { _, _ in }
    var exitPlanReply: @MainActor (MobileAgentFeedItem, _ mode: String, _ feedback: String?) -> Void = { _, _, _ in }
    var terminalReply: @MainActor (MobileAgentFeedItem, _ text: String) -> Void = { _, _ in }
    var refresh: @MainActor () async -> Void = {}
}

/// One X-style full-width Feed row: avatar gutter, author line, inline agent
/// output, and — for respondable rows — the decision controls themselves.
struct AgentFeedRow: View, Equatable {
    let model: AgentFeedRowModel
    let isReplyPending: Bool
    let now: Date
    let actions: AgentFeedActions

    /// Rows re-render only when their item, pending flag, or time reference
    /// changes; `actions` closures are excluded by design.
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.model == rhs.model
            && lhs.isReplyPending == rhs.isReplyPending
            && lhs.now == rhs.now
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
                    AgentFeedRowOutputText(
                        text: output,
                        isExpandable: model.presentation.outputIsExpandable
                    )
                }
                if let toolLine = model.presentation.toolLine {
                    Text(toolLine)
                        .font(.caption.monospaced())
                        .foregroundStyle(model.item.toolResultIsError ? .red : .secondary)
                        .lineLimit(2)
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
                    AgentFeedInlineReplyField(
                        item: model.item,
                        isReplyPending: isReplyPending,
                        actions: actions
                    )
                }
            }
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }

    private var avatar: some View {
        ZStack {
            Circle()
                .fill(Color.secondary.opacity(0.12))
                .frame(width: 40, height: 40)
            TaskTemplateIcon(value: model.presentation.authorIconValue, size: 22)
        }
        .overlay(alignment: .bottomTrailing) {
            if model.item.needsInput {
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
            Text(agentFeedCompactTimeLabel(for: model.item.createdAt, now: now))
                .font(.caption)
                .foregroundStyle(.tertiary)
                .layoutPriority(2)
        }
    }

    private func quotedMessage(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(Color.secondary.opacity(0.35))
                .frame(width: 3)
            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(3)
        }
        .fixedSize(horizontal: false, vertical: true)
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

/// The inline agent output, collapsed past ~600 characters behind a local
/// "Show more" toggle (plan texts routinely run pages long).
private struct AgentFeedRowOutputText: View {
    let text: String
    let isExpandable: Bool
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .lineLimit(isExpandable && !isExpanded ? 10 : nil)
                .fixedSize(horizontal: false, vertical: true)
            if isExpandable {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        isExpanded.toggle()
                    }
                } label: {
                    Text(isExpanded
                        ? String(
                            localized: "mobile.agentFeed.showLess",
                            defaultValue: "Show less",
                            bundle: .module
                        )
                        : String(
                            localized: "mobile.agentFeed.showMore",
                            defaultValue: "Show more",
                            bundle: .module
                        ))
                        .font(.footnote.weight(.medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
            }
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
            Button {
                actions.permissionReply(item, "once")
            } label: {
                Text(String(
                    localized: "mobile.agentFeed.permission.allow",
                    defaultValue: "Allow",
                    bundle: .module
                ))
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)

            Button {
                actions.permissionReply(item, "always")
            } label: {
                Text(String(
                    localized: "mobile.agentFeed.permission.always",
                    defaultValue: "Always",
                    bundle: .module
                ))
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button(role: .destructive) {
                actions.permissionReply(item, "deny")
            } label: {
                Text(String(
                    localized: "mobile.agentFeed.permission.deny",
                    defaultValue: "Deny",
                    bundle: .module
                ))
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

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
                Image(systemName: "ellipsis.circle")
                    .font(.body)
                    .foregroundStyle(.secondary)
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
    @State private var isRevising = false
    @State private var feedbackDraft = ""

    private var approveMode: String { item.defaultExitPlanMode ?? "manual" }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    actions.exitPlanReply(item, approveMode, nil)
                } label: {
                    Text(String(
                        localized: "mobile.agentFeed.exitPlan.approve",
                        defaultValue: "Approve",
                        bundle: .module
                    ))
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        isRevising.toggle()
                    }
                } label: {
                    Text(String(
                        localized: "mobile.agentFeed.exitPlan.revise",
                        defaultValue: "Revise…",
                        bundle: .module
                    ))
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button(role: .destructive) {
                    actions.exitPlanReply(item, "deny", nil)
                } label: {
                    Text(String(
                        localized: "mobile.agentFeed.permission.deny",
                        defaultValue: "Deny",
                        bundle: .module
                    ))
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Menu {
                    ForEach(AgentFeedExitPlanControls.approveModes, id: \.mode) { entry in
                        Button {
                            actions.exitPlanReply(item, entry.mode, nil)
                        } label: {
                            Text(entry.label)
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel(String(
                    localized: "mobile.agentFeed.exitPlan.moreModes",
                    defaultValue: "More approval modes",
                    bundle: .module
                ))
            }
            if isRevising {
                AgentFeedSendableTextField(
                    placeholder: String(
                        localized: "mobile.agentFeed.exitPlan.revisePlaceholder",
                        defaultValue: "What should change?",
                        bundle: .module
                    ),
                    text: $feedbackDraft
                ) { feedback in
                    actions.exitPlanReply(item, "manual", feedback)
                }
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

/// Option chips (single-select answers immediately, multi-select accumulates
/// behind Send) plus an "Other…" free-text lane, mirroring the Mac Feed
/// panel's question semantics.
private struct AgentFeedQuestionControls: View {
    let item: MobileAgentFeedItem
    let isReplyPending: Bool
    let actions: AgentFeedActions
    @State private var selectedOptionIDs: Set<String> = []
    @State private var isAnsweringOther = false
    @State private var otherDraft = ""

    private var question: MobileAgentFeedQuestion? { item.questions.first }
    private var isMultiSelect: Bool { question?.multiSelect ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Poll-style stacked options; a pending question whose prompt
            // failed to parse still gets the free-text lane, so no
            // respondable row is ever a dead end.
            VStack(alignment: .leading, spacing: 6) {
                ForEach(question?.options ?? [], id: \.id) { option in
                    optionChip(option)
                }
                otherChip
            }
            if isMultiSelect, !selectedOptionIDs.isEmpty {
                Button {
                    let ordered = (question?.options ?? [])
                        .map(\.id)
                        .filter { selectedOptionIDs.contains($0) }
                    actions.questionReply(item, ordered)
                } label: {
                    Text(String(
                        localized: "mobile.agentFeed.question.send",
                        defaultValue: "Send",
                        bundle: .module
                    ))
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            if isAnsweringOther {
                AgentFeedSendableTextField(
                    placeholder: String(
                        localized: "mobile.agentFeed.question.otherPlaceholder",
                        defaultValue: "Your answer",
                        bundle: .module
                    ),
                    text: $otherDraft
                ) { answer in
                    actions.questionReply(item, [answer])
                }
            }
        }
    }

    private func optionChip(_ option: MobileAgentFeedQuestionOption) -> some View {
        let isSelected = selectedOptionIDs.contains(option.id)
        return Button {
            if isMultiSelect {
                if isSelected {
                    selectedOptionIDs.remove(option.id)
                } else {
                    selectedOptionIDs.insert(option.id)
                }
            } else {
                actions.questionReply(item, [option.id])
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(option.label)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                if let description = option.description {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10).fill(
                    isSelected
                        ? Color.accentColor.opacity(0.22)
                        : Color.secondary.opacity(0.12)
                )
            )
        }
        .buttonStyle(.plain)
    }

    private var otherChip: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                isAnsweringOther.toggle()
            }
        } label: {
            Text(String(
                localized: "mobile.agentFeed.question.other",
                defaultValue: "Other…",
                bundle: .module
            ))
            .font(.subheadline.weight(.medium))
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.secondary.opacity(0.35))
            )
        }
        .buttonStyle(.plain)
    }
}

/// The turn-complete inline reply lane: text field plus send, routed to the
/// owning terminal via the same path push-notification replies use.
private struct AgentFeedInlineReplyField: View {
    let item: MobileAgentFeedItem
    let isReplyPending: Bool
    let actions: AgentFeedActions
    @State private var draft = ""

    var body: some View {
        AgentFeedSendableTextField(
            placeholder: String(
                localized: "mobile.agentFeed.reply.placeholder",
                defaultValue: "Reply to agent…",
                bundle: .module
            ),
            text: $draft
        ) { text in
            actions.terminalReply(item, text)
        }
        .disabled(isReplyPending)
        .padding(.top, 4)
    }
}

/// A bordered text field with a trailing send affordance. Submitting trims,
/// sends through `onSend`, and clears the draft.
private struct AgentFeedSendableTextField: View {
    let placeholder: String
    @Binding var text: String
    let onSend: @MainActor (String) -> Void

    var body: some View {
        HStack(spacing: 8) {
            TextField(placeholder, text: $text, axis: .vertical)
                .font(.subheadline)
                .lineLimit(1...4)
                .textFieldStyle(.plain)
                .onSubmit(send)
            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title3)
            }
            .buttonStyle(.plain)
            .foregroundStyle(
                text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? Color.secondary.opacity(0.4)
                    : Color.accentColor
            )
            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityLabel(String(
                localized: "mobile.agentFeed.reply.send",
                defaultValue: "Send reply",
                bundle: .module
            ))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(Color.secondary.opacity(0.25))
        )
    }

    private func send() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onSend(trimmed)
        text = ""
    }
}

#endif
