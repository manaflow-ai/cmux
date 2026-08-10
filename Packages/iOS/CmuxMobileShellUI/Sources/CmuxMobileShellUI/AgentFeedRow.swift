#if os(iOS)
import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

struct AgentFeedRowActions {
    let setExpanded: @MainActor (Bool) -> Void
    let setDraft: @MainActor (String) -> Void
    let setPlanFeedback: @MainActor (String) -> Void
    let setQuestionSelection: @MainActor (String, Set<String>) -> Void
    let setOtherAnswer: @MainActor (String, String) -> Void
    let reply: @MainActor () -> Void
    let decide: @MainActor (MobileAgentFeedAction) -> Void
    let open: @MainActor () -> Void
}

struct AgentFeedRow: View, Equatable {
    let item: MobileAgentFeedItem
    let isExpanded: Bool
    let draft: String
    let mutationState: MobileAgentFeedMutationState
    let interactionsEnabled: Bool
    let planFeedback: String
    let questionSelections: [String: Set<String>]
    let otherAnswers: [String: String]
    let actions: AgentFeedRowActions
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.item == rhs.item
            && lhs.isExpanded == rhs.isExpanded
            && lhs.draft == rhs.draft
            && lhs.mutationState == rhs.mutationState
            && lhs.interactionsEnabled == rhs.interactionsEnabled
            && lhs.planFeedback == rhs.planFeedback
            && lhs.questionSelections == rhs.questionSelections
            && lhs.otherAnswers == rhs.otherAnswers
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            DisclosureGroup(
                isExpanded: Binding(
                    get: { isExpanded },
                    set: { newValue in actions.setExpanded(newValue) }
                )
            ) {
                actionArea
            } label: {
                VStack(alignment: .leading, spacing: 10) {
                    AgentFeedRowHeader(item: item)
                    AgentFeedContext(item: item, isExpanded: isExpanded)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("MobileAgentFeedExpand-\(suffix)")
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            footer
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("MobileAgentFeedCard-\(suffix)")
    }

    @ViewBuilder
    private var footer: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 4) {
                mutationCaption
                openAgentControl
            }
        } else {
            HStack {
                mutationCaption
                Spacer()
                openAgentControl
            }
        }
    }

    @ViewBuilder
    private var openAgentControl: some View {
        if item.wire.workspaceID != nil, item.wire.surfaceID != nil {
            Button(action: actions.open) {
                Label(
                    AgentFeedL10n.string("mobile.agentFeed.openAgent", defaultValue: "Open Agent"),
                    systemImage: "terminal"
                )
            }
            .frame(minHeight: 44)
            .buttonStyle(.borderless)
            .disabled(!interactionsEnabled)
            .accessibilityIdentifier("MobileAgentFeedOpenAgent-\(suffix)")
        } else {
            Text(AgentFeedL10n.string("mobile.agentFeed.targetUnavailable", defaultValue: "Agent location unavailable"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var actionArea: some View {
        switch item.wire.payload {
        case .permission(_, let toolName, let safeInput, let supportedModes):
            VStack(alignment: .leading, spacing: 8) {
                Text(toolName).font(.headline)
                if !safeInput.isEmpty { Text(safeInput).font(.caption).foregroundStyle(.secondary) }
                ViewThatFits {
                    HStack { permissionButtons(supportedModes) }
                    VStack(alignment: .leading) { permissionButtons(supportedModes) }
                }
            }
        case .exitPlan(_, let plan, let summary, _):
            VStack(alignment: .leading, spacing: 8) {
                if let summary { Text(summary).font(.headline) }
                Text(plan).font(.body).textSelection(.enabled)
                TextField(
                    AgentFeedL10n.string("mobile.agentFeed.plan.feedback", defaultValue: "Request changes"),
                    text: Binding(get: { planFeedback }, set: { actions.setPlanFeedback($0) }),
                    axis: .vertical
                )
                .lineLimit(2...6)
                .disabled(!interactionsEnabled || isSending)
                .accessibilityIdentifier("MobileAgentFeedPlanFeedback-\(suffix)")
                ViewThatFits {
                    HStack { planButtons }
                    VStack(alignment: .leading) { planButtons }
                }
            }
        case .question(_, let questions):
            if questions.isEmpty {
                Text(AgentFeedL10n.string("mobile.agentFeed.question.malformed", defaultValue: "This question could not be displayed. Open the agent to respond."))
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(questions) { question in questionView(question) }
                    Button(AgentFeedL10n.string("mobile.agentFeed.question.submit", defaultValue: "Submit Answers")) {
                        actions.decide(.question(selections: encodedQuestionAnswers(questions)))
                    }
                    .disabled(!interactionsEnabled || isSending || !questionsAreValid(questions))
                    .frame(minHeight: 44)
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("MobileAgentFeedQuestionSubmit-\(suffix)")
                }
            }
        case .stop:
            replyComposer
        case .lifecycle where item.wire.kind == "sessionEnd":
            replyComposer
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private func permissionButtons(_ modes: [String]) -> some View {
        ForEach(modes, id: \.self) { mode in
            Button(AgentFeedCopy.permissionModeLabel(mode)) { actions.decide(.permission(mode: mode)) }
                .disabled(!interactionsEnabled || isSending || !item.wire.status.isPending)
                .frame(minHeight: 44)
                .buttonStyle(.borderless)
                .accessibilityIdentifier("MobileAgentFeedPermission-\(mode)-\(suffix)")
        }
    }

    @ViewBuilder
    private var planButtons: some View {
        ForEach(["ultraplan", "bypassPermissions", "autoAccept", "manual", "deny"], id: \.self) { mode in
            Button(AgentFeedCopy.planModeLabel(mode)) {
                actions.decide(.exitPlan(
                    mode: mode,
                    feedback: planFeedback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : planFeedback
                ))
            }
            .disabled(!interactionsEnabled || isSending || !item.wire.status.isPending)
            .frame(minHeight: 44)
            .buttonStyle(.borderless)
            .accessibilityIdentifier("MobileAgentFeedPlan-\(mode)-\(suffix)")
        }
    }

    private var replyComposer: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField(
                AgentFeedL10n.string("mobile.agentFeed.reply.placeholder", defaultValue: "Reply to this agent"),
                text: Binding(get: { draft }, set: { actions.setDraft($0) }),
                axis: .vertical
            )
            .lineLimit(2...8)
            .disabled(!interactionsEnabled || isSending)
            .accessibilityIdentifier("MobileAgentFeedReplyComposer-\(suffix)")
            Button(AgentFeedL10n.string("mobile.agentFeed.reply.send", defaultValue: "Send Reply"), action: actions.reply)
                .disabled(!interactionsEnabled || isSending || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || item.wire.surfaceID == nil)
                .frame(minHeight: 44)
                .buttonStyle(.borderless)
                .accessibilityIdentifier("MobileAgentFeedReplySubmit-\(suffix)")
        }
    }

    private func questionView(_ question: MobileWorkstreamQuestion) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let header = question.header { Text(header).font(.caption.weight(.semibold)) }
            Text(question.prompt).font(.headline)
            ForEach(question.options) { option in
                Button {
                    var selections = questionSelections[question.id] ?? []
                    if question.multiSelect {
                        if selections.contains(option.id) { selections.remove(option.id) } else { selections.insert(option.id) }
                    } else {
                        selections = [option.id]
                    }
                    actions.setQuestionSelection(question.id, selections)
                } label: {
                    HStack(alignment: .top) {
                        Image(systemName: selectionSymbol(question, option.id))
                        VStack(alignment: .leading) {
                            Text(option.label)
                            if let description = option.description {
                                Text(description).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .buttonStyle(.plain)
                .frame(minHeight: 44)
                .disabled(!interactionsEnabled || isSending)
                .accessibilityIdentifier("MobileAgentFeedQuestion-\(question.id)-\(option.id)-\(suffix)")
            }
            TextField(
                AgentFeedL10n.string("mobile.agentFeed.question.other", defaultValue: "Other"),
                text: Binding(
                    get: { otherAnswers[question.id] ?? "" },
                    set: { actions.setOtherAnswer(question.id, $0) }
                ),
                axis: .vertical
            )
            .lineLimit(1...4)
            .disabled(!interactionsEnabled || isSending)
            .accessibilityIdentifier("MobileAgentFeedQuestionOther-\(question.id)-\(suffix)")
        }
    }

    private func selectionSymbol(_ question: MobileWorkstreamQuestion, _ optionID: String) -> String {
        let selected = questionSelections[question.id]?.contains(optionID) == true
        if question.multiSelect { return selected ? "checkmark.square.fill" : "square" }
        return selected ? "largecircle.fill.circle" : "circle"
    }

    private func questionsAreValid(_ questions: [MobileWorkstreamQuestion]) -> Bool {
        questions.allSatisfy { question in
            let selectedCount = (questionSelections[question.id] ?? []).count
            let hasOther = !(otherAnswers[question.id] ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let answerCount = selectedCount + (hasOther ? 1 : 0)
            return question.multiSelect ? answerCount > 0 : answerCount == 1
        }
    }

    private func encodedQuestionAnswers(_ questions: [MobileWorkstreamQuestion]) -> [String] {
        questions.flatMap { question in
            let selected = (questionSelections[question.id] ?? []).sorted().map { "\(question.id)=\($0)" }
            let other = (otherAnswers[question.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return selected + (other.isEmpty ? [] : ["\(question.id)=other:\(other)"])
        }
    }

    private var isSending: Bool {
        if case .sending = mutationState { return true }
        return false
    }

    @ViewBuilder private var mutationCaption: some View {
        switch mutationState {
        case .idle: EmptyView()
        case .sending:
            Label(AgentFeedL10n.string("mobile.agentFeed.status.sending", defaultValue: "Sending…"), systemImage: "paperplane")
                .font(.caption)
                .accessibilityIdentifier("MobileAgentFeedSending-\(suffix)")
        case .failed:
            Label(AgentFeedL10n.string("mobile.agentFeed.status.failed", defaultValue: "Failed. Try again."), systemImage: "exclamationmark.circle")
                .font(.caption).foregroundStyle(.red)
                .accessibilityIdentifier("MobileAgentFeedFailed-\(suffix)")
        }
    }

    private var suffix: String { "\(item.macDeviceID)-\(item.wire.id.uuidString)" }
}

private struct AgentFeedRowHeader: View {
    let item: MobileAgentFeedItem
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: item.wire.status.isPending ? "exclamationmark.bubble.fill" : "bubble.left.and.text.bubble.right")
            VStack(alignment: .leading) {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 5) {
                        sourceLabel
                        statusLabel
                    }
                } else {
                    HStack {
                        sourceLabel
                        statusLabel
                    }
                }
                Text(computerContext)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                    .fixedSize(horizontal: false, vertical: dynamicTypeSize.isAccessibilitySize)
                if dynamicTypeSize.isAccessibilitySize { relativeTime }
            }
            Spacer(minLength: 8)
            if !dynamicTypeSize.isAccessibilitySize { relativeTime }
        }
    }

    private var sourceLabel: some View {
        Text(AgentFeedCopy.sourceLabel(item.wire.source))
            .font(.headline)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var statusLabel: some View {
        Text(AgentFeedCopy.statusLabel(item.wire.status))
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(.secondary.opacity(0.12), in: Capsule())
            .fixedSize(horizontal: false, vertical: true)
    }

    private var computerContext: String {
        String(
            format: AgentFeedL10n.string(
                "mobile.agentFeed.card.computerContext",
                defaultValue: "%@ · %@ · %@"
            ),
            item.macDisplayName,
            item.connectionStatus.label,
            item.wire.workstreamID
        )
    }

    private var relativeTime: some View {
        Text(item.wire.createdAt, format: .relative(presentation: .named, unitsStyle: .abbreviated))
            .font(.caption2)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct AgentFeedContext: View {
    let item: MobileAgentFeedItem
    let isExpanded: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let title = item.wire.title {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(AgentFeedCopy.payloadSummary(item.wire.payload))
                .font(.subheadline)
                .lineLimit(isExpanded || dynamicTypeSize.isAccessibilitySize ? nil : 4)
                .fixedSize(horizontal: false, vertical: true)
            if case .resolved(let decision) = item.wire.status,
               let decision = AgentFeedCopy.decisionLabel(decision) {
                Text(
                    String(
                        format: AgentFeedL10n.string(
                            "mobile.agentFeed.card.resolution",
                            defaultValue: "Resolved: %@"
                        ),
                        decision
                    )
                )
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            }
            if let cwd = item.wire.cwd {
                Text(cwd)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                    .fixedSize(horizontal: false, vertical: dynamicTypeSize.isAccessibilitySize)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct AgentFeedCopy {
    static func statusLabel(_ status: MobileWorkstreamFeedStatus) -> String {
        switch status {
        case .pending: AgentFeedL10n.string("mobile.agentFeed.card.pending", defaultValue: "Needs input")
        case .resolved: AgentFeedL10n.string("mobile.agentFeed.card.resolved", defaultValue: "Resolved")
        case .expired: AgentFeedL10n.string("mobile.agentFeed.card.expired", defaultValue: "Expired")
        case .telemetry: AgentFeedL10n.string("mobile.agentFeed.card.activity", defaultValue: "Activity")
        case .unknown: AgentFeedL10n.string("mobile.agentFeed.card.unknown", defaultValue: "Unknown status")
        }
    }

    static func sourceLabel(_ source: String) -> String {
        switch source {
        case "claude": return AgentFeedL10n.string("mobile.agentFeed.source.claude", defaultValue: "Claude")
        case "codex": return AgentFeedL10n.string("mobile.agentFeed.source.codex", defaultValue: "Codex")
        case "opencode": return AgentFeedL10n.string("mobile.agentFeed.source.opencode", defaultValue: "OpenCode")
        case "hermes-agent": return AgentFeedL10n.string("mobile.agentFeed.source.hermes", defaultValue: "Hermes")
        case "gemini": return AgentFeedL10n.string("mobile.agentFeed.source.gemini", defaultValue: "Gemini")
        default:
            return String(
                format: AgentFeedL10n.string("mobile.agentFeed.source.other", defaultValue: "Agent: %@"),
                source
            )
        }
    }

    static func payloadSummary(_ payload: MobileWorkstreamFeedPayload) -> String {
        switch payload {
        case .permission(_, let tool, let summary, _): return summary.isEmpty ? tool : "\(tool)\n\(summary)"
        case .exitPlan(_, let plan, _, _): return plan
        case .question(_, let questions): return questions.map(\.prompt).formatted()
        case .toolUse(let name, _):
            return String(format: AgentFeedL10n.string("mobile.agentFeed.activity.toolUse", defaultValue: "Using %@"), name)
        case .toolResult(let name, let result, let isError):
            return isError
                ? String(
                    format: AgentFeedL10n.string("mobile.agentFeed.activity.toolError", defaultValue: "%@ failed: %@"),
                    name,
                    result
                )
                : result
        case .message(let text, _): return text
        case .stop(let reason): return reason ?? AgentFeedL10n.string("mobile.agentFeed.activity.turnComplete", defaultValue: "Turn complete. Reply to continue.")
        case .todos: return AgentFeedL10n.string("mobile.agentFeed.activity.todos", defaultValue: "Task list updated")
        case .lifecycle: return AgentFeedL10n.string("mobile.agentFeed.activity.lifecycle", defaultValue: "Session activity")
        case .unknown: return AgentFeedL10n.string("mobile.agentFeed.activity.unknown", defaultValue: "Agent activity")
        }
    }

    static func permissionModeLabel(_ mode: String) -> String {
        switch mode {
        case "once": AgentFeedL10n.string("mobile.agentFeed.permission.once", defaultValue: "Allow Once")
        case "always": AgentFeedL10n.string("mobile.agentFeed.permission.always", defaultValue: "Always Allow")
        case "all": AgentFeedL10n.string("mobile.agentFeed.permission.all", defaultValue: "Allow All")
        case "bypass": AgentFeedL10n.string("mobile.agentFeed.permission.bypass", defaultValue: "Bypass")
        default: AgentFeedL10n.string("mobile.agentFeed.permission.deny", defaultValue: "Deny")
        }
    }

    static func decisionLabel(_ decision: MobileWorkstreamDecision?) -> String? {
        switch decision {
        case .permission(let mode): return permissionModeLabel(mode)
        case .exitPlan(let mode, let feedback):
            let label = planModeLabel(mode)
            if let feedback, !feedback.isEmpty { return "\(label): \(feedback)" }
            return label
        case .question(let selections): return selections.formatted()
        case .unknown(let kind): return kind
        case nil: return nil
        }
    }

    static func planModeLabel(_ mode: String) -> String {
        switch mode {
        case "ultraplan": AgentFeedL10n.string("mobile.agentFeed.plan.ultraplan", defaultValue: "Ultraplan")
        case "bypassPermissions": AgentFeedL10n.string("mobile.agentFeed.plan.bypass", defaultValue: "Bypass Permissions")
        case "autoAccept": AgentFeedL10n.string("mobile.agentFeed.plan.autoAccept", defaultValue: "Auto-Accept")
        case "manual": AgentFeedL10n.string("mobile.agentFeed.plan.manual", defaultValue: "Manual")
        default: AgentFeedL10n.string("mobile.agentFeed.plan.deny", defaultValue: "Deny")
        }
    }
}
#endif
