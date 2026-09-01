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
    /// Opens the X-style reply composer sheet; rows never host a keyboard.
    var beginCompose: @MainActor (MobileAgentFeedItem, AgentFeedComposeContext.Kind) -> Void = { _, _ in }
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
        .accessibilityElement(children: .combine)
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

    /// The reply affordance under a finished turn: accent-tinted so it reads
    /// as the row's obvious action, opening the composer sheet.
    private var replyButton: some View {
        Button {
            actions.beginCompose(model.item, .terminalReply)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrowshape.turn.up.left.fill")
                    .font(.footnote)
                Text(String(
                    localized: "mobile.agentFeed.compose.reply",
                    defaultValue: "Reply",
                    bundle: .module
                ))
                .font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.accentColor.opacity(0.12))
            )
        }
        .buttonStyle(.plain)
        .disabled(isReplyPending)
        .padding(.top, 2)
        .accessibilityIdentifier("MobileAgentFeedReplyButton")
    }

    /// The user's recorded reply, quote-referencing the message it answered.
    private func userReplyMarker(reply: String, reference: String?) -> some View {
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
                Text(reply)
                    .font(.footnote)
                    .foregroundStyle(.primary)
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
                .lineLimit(isExpandable && !isExpanded ? 8 : nil)
                .fixedSize(horizontal: false, vertical: true)
            if isExpandable {
                Button {
                    // No animation: the row grows downward in place, so the
                    // top of the row never moves while expanding.
                    isExpanded.toggle()
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

/// Option chips (single-select answers immediately, multi-select accumulates
/// behind Send) plus an "Other…" free-text lane, mirroring the Mac Feed
/// panel's question semantics.
private struct AgentFeedQuestionControls: View {
    let item: MobileAgentFeedItem
    let isReplyPending: Bool
    let actions: AgentFeedActions
    @State private var selectedOptionIDs: Set<String> = []

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
            actions.beginCompose(item, .questionOther)
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

#endif
