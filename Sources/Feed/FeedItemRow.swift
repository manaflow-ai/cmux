import AppKit
import Bonsplit
import CMUXWorkstream
import SwiftUI

/// Immutable snapshot of a `WorkstreamItem` handed to row views so rows
/// never hold a reference to the store.
struct FeedItemSnapshot: Equatable {
    let id: UUID
    let workstreamId: String
    let source: WorkstreamSource
    let kind: WorkstreamKind
    let title: String?
    let cwd: String?
    let createdAt: Date
    let status: WorkstreamStatus
    let payload: WorkstreamPayload
    let context: WorkstreamContext?
    /// Most recent user-prompt text in the same workstream, attached
    /// by the list view so every card can show a "You: …" echo for
    /// context, even when the agent payload doesn't carry it directly.
    let userPromptEcho: String?

    init(item: WorkstreamItem, userPromptEcho: String? = nil) {
        self.id = item.id
        self.workstreamId = item.workstreamId
        self.source = item.source
        self.kind = item.kind
        self.title = item.title
        self.cwd = item.cwd
        self.createdAt = item.createdAt
        self.status = item.status
        self.payload = item.payload
        self.context = item.context
        self.userPromptEcho = userPromptEcho
    }
}

/// Closure bundle; binds to `FeedCoordinator` by default.
struct FeedRowActions {
    let approvePermission: (UUID, WorkstreamPermissionMode) -> Void
    let replyQuestion: (UUID, [String]) -> Void
    let approveExitPlan: (UUID, WorkstreamExitPlanMode, String?) -> Void
    let jump: (String) -> Void
    /// Types the user's reply into the agent's terminal surface and
    /// presses Return. Used by Stop-kind cards so the user can nudge
    /// Claude without switching focus to the terminal.
    let sendText: (String, String) -> Void

    static func bound() -> FeedRowActions {
        FeedRowActions(
            approvePermission: { itemId, mode in
                Task { @MainActor in
                    FeedCoordinator.shared.deliverReply(
                        requestId: Self.requestId(for: itemId) ?? itemId.uuidString,
                        decision: .permission(mode)
                    )
                }
            },
            replyQuestion: { itemId, selections in
                Task { @MainActor in
                    FeedCoordinator.shared.deliverReply(
                        requestId: Self.requestId(for: itemId) ?? itemId.uuidString,
                        decision: .question(selections: selections)
                    )
                }
            },
            approveExitPlan: { itemId, mode, feedback in
                Task { @MainActor in
                    FeedCoordinator.shared.deliverReply(
                        requestId: Self.requestId(for: itemId) ?? itemId.uuidString,
                        decision: .exitPlan(mode, feedback: feedback)
                    )
                }
            },
            jump: { workstreamId in
                Task { @MainActor in
                    _ = FeedCoordinator.shared.focusIfPossible(workstreamId: workstreamId)
                }
            },
            sendText: { workstreamId, text in
                Task { @MainActor in
                    FeedCoordinator.shared.sendTextToWorkstream(
                        workstreamId: workstreamId,
                        text: text
                    )
                }
            }
        )
    }

    @MainActor
    private static func requestId(for itemId: UUID) -> String? {
        guard let store = FeedCoordinator.shared.store else { return nil }
        return store.items.first(where: { $0.id == itemId }).flatMap { item in
            switch item.payload {
            case .permissionRequest(let rid, _, _, _): return rid
            case .exitPlan(let rid, _, _): return rid
            case .question(let rid, _): return rid
            default: return nil
            }
        }
    }
}

// MARK: - Row (matches SessionIndexView row aesthetic)

struct FeedItemRow: View, Equatable {
    let snapshot: FeedItemSnapshot
    let actions: FeedRowActions
    let isSelected: Bool
    let onPressSelect: () -> Void
    let onControlFocus: () -> Void
    let onControlAction: () -> Void
    let onControlBlur: () -> Void
    let onActivate: () -> Void
    @Binding var stopDraft: FeedStopDraft
    let stopDraftValue: FeedStopDraft
    @Binding var stopFocusRequest: Int
    let stopFocusRequestValue: Int

    @State private var didHandlePressSelection = false

    static func == (lhs: FeedItemRow, rhs: FeedItemRow) -> Bool {
        lhs.snapshot == rhs.snapshot
            && lhs.isSelected == rhs.isSelected
            && lhs.stopDraftValue == rhs.stopDraftValue
            && lhs.stopFocusRequestValue == rhs.stopFocusRequestValue
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            chipHeader
            if let context = displayContext {
                FeedContextBlock(context: context, source: snapshot.source)
            } else if let echo = promptEcho, !echo.isEmpty {
                Text(echo)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .truncationMode(.tail)
            }
            actionArea
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(isResolvedOrExpired ? 0.6 : 1.0)
        .contentShape(Rectangle())
        .help(helpText)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    if !didHandlePressSelection {
                        didHandlePressSelection = true
                        onPressSelect()
                    }
                }
                .onEnded { _ in
                    didHandlePressSelection = false
                }
        )
        .onTapGesture(count: 2, perform: onActivate)
    }

    private var promptEcho: String? {
        // Prefer the real user prompt attached by the list view (walks
        // the same workstream for the most recent .userPrompt
        // telemetry). Synthetic permission labels are intentionally
        // avoided here because the Feed should show real context only.
        if let echo = snapshot.userPromptEcho,
           !echo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return String(localized: "feed.promptEcho", defaultValue: "You: \(echo)")
        }
        return nil
    }

    private var displayContext: WorkstreamContext? {
        let fallback = WorkstreamContext(lastUserMessage: snapshot.userPromptEcho)
        let context = snapshot.context?.mergingMissing(from: fallback) ?? fallback
        return context.isEmpty ? nil : context
    }

    private var isResolvedOrExpired: Bool {
        switch snapshot.status {
        case .pending: return false
        case .telemetry: return false
        case .resolved, .expired: return true
        }
    }

    /// Compact header: kind icon + project/path title on the left,
    /// agent and age on the right.
    private var chipHeader: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: snapshot.kind.symbolName)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(kindTint)
                .frame(width: 14, height: 14)
            Text(headerTitle)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.primary.opacity(0.92))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            HStack(spacing: 4) {
                chip(
                    text: snapshot.source.rawValue.capitalized,
                    fg: sourceChipForeground,
                    bg: sourceChipBackground
                )
                chip(
                    text: relativeTimeChip(snapshot.createdAt),
                    fg: .secondary,
                    bg: Color.primary.opacity(0.10),
                    mono: true
                )
            }
        }
    }

    private var headerTitle: String {
        // Prefer the user prompt as the card title, but keep question
        // headers before it so short labels like "Demo style" survive
        // middle truncation.
        let promptLine = (displayContext?.lastUserMessage ?? snapshot.userPromptEcho)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let questionHeader = questionHeaderForTitle
        if !promptLine.isEmpty {
            let detail = [questionHeader, promptLine].compactMap { $0 }.joined(separator: " · ")
            if let cwd = snapshot.cwd, !cwd.isEmpty {
                return "\(cwdBasename(cwd)) · \(detail)"
            }
            return detail
        }
        if let questionHeader {
            if let cwd = snapshot.cwd, !cwd.isEmpty {
                return "\(cwdBasename(cwd)) · \(questionHeader)"
            }
            return questionHeader
        }
        if let title = snapshot.title, !title.isEmpty {
            if let cwd = snapshot.cwd, !cwd.isEmpty {
                return "\(cwdBasename(cwd)) · \(title)"
            }
            return title
        }
        if let cwd = snapshot.cwd, !cwd.isEmpty {
            return "\(cwdBasename(cwd)) · \(kindLabel.capitalized)"
        }
        return kindLabel.capitalized
    }

    private var questionHeaderForTitle: String? {
        guard case .question(_, let questions) = snapshot.payload else { return nil }
        return questions
            .compactMap { $0.header?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }

    /// Last path component only — `fun` instead of `~/fun` or the full
    /// absolute path. Matches the Vibe-Island mockup's compact header.
    private func cwdBasename(_ path: String) -> String {
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        let name = (trimmed as NSString).lastPathComponent
        return name.isEmpty ? path : name
    }

    private func chip(text: String, fg: Color, bg: Color, mono: Bool = false) -> some View {
        Text(text)
            .font(mono
                  ? .system(size: 10, weight: .medium).monospacedDigit()
                  : .system(size: 10, weight: .medium))
            .foregroundColor(fg)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(bg)
            )
    }

    private var sourceChipForeground: Color {
        switch snapshot.source {
        case .claude: return Color(red: 0.92, green: 0.54, blue: 0.29)
        case .codex: return .green
        case .opencode: return .blue
        case .hermesAgent: return .teal
        case .cursor: return .purple
        default: return .secondary
        }
    }
    private var sourceChipBackground: Color {
        return sourceChipForeground.opacity(0.18)
    }

    private func relativeTimeChip(_ date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 60 { return "<1m" }
        if interval < 3600 { return "\(Int(interval / 60))m" }
        if interval < 86_400 { return "\(Int(interval / 3600))h" }
        return "\(Int(interval / 86_400))d"
    }

    private var kindLabel: String {
        switch snapshot.kind {
        case .permissionRequest:
            return String(localized: "feed.kind.permission", defaultValue: "PERMISSION")
        case .exitPlan:
            return String(localized: "feed.kind.plan", defaultValue: "PLAN")
        case .question:
            return String(localized: "feed.kind.question.upper", defaultValue: "QUESTION")
        case .toolUse:
            return String(localized: "feed.kind.toolUse", defaultValue: "TOOL USE")
        case .toolResult:
            return String(localized: "feed.kind.toolResult", defaultValue: "TOOL RESULT")
        case .userPrompt:
            return String(localized: "feed.kind.prompt", defaultValue: "PROMPT")
        case .assistantMessage:
            return String(localized: "feed.kind.message", defaultValue: "MESSAGE")
        case .sessionStart:
            return String(localized: "feed.kind.sessionStart.upper", defaultValue: "SESSION START")
        case .sessionEnd:
            return String(localized: "feed.kind.sessionEnd.upper", defaultValue: "SESSION END")
        case .stop:
            return String(localized: "feed.kind.stop", defaultValue: "STOP")
        case .todos:
            return String(localized: "feed.kind.todos", defaultValue: "TODOS")
        }
    }

    private var kindTint: Color {
        switch snapshot.kind {
        case .permissionRequest: return .orange
        case .exitPlan: return .purple
        case .question: return .blue
        default: return snapshot.status.isPending ? .orange : .secondary.opacity(0.8)
        }
    }

    @ViewBuilder
    private var actionArea: some View {
        switch snapshot.payload {
        case .permissionRequest(_, let toolName, let toolInputJSON, _):
            PermissionActionArea(
                toolName: toolName,
                toolInputJSON: toolInputJSON,
                source: snapshot.source,
                status: snapshot.status,
                onActionRow: onControlAction,
                onApprove: { mode in
                    actions.approvePermission(snapshot.id, mode)
                }
            )
        case .exitPlan(_, let plan, _):
            ExitPlanActionArea(
                plan: plan,
                source: snapshot.source,
                status: snapshot.status,
                isRowSelected: isSelected,
                onFocusRow: onControlFocus,
                onActionRow: onControlAction,
                onBlurRow: onControlBlur,
                onApprove: { mode, feedback in
                    actions.approveExitPlan(snapshot.id, mode, feedback)
                }
            )
        case .question(_, let questions):
            QuestionActionArea(
                questions: questions,
                source: snapshot.source,
                status: snapshot.status,
                isRowSelected: isSelected,
                onFocusRow: onControlFocus,
                onActionRow: onControlAction,
                onBlurRow: onControlBlur,
                context: displayContext,
                onReply: { selections in
                    actions.replyQuestion(snapshot.id, selections)
                }
            )
        case .stop:
            StopActionArea(
                draft: $stopDraft,
                focusRequest: $stopFocusRequest,
                onFocusRow: onControlFocus,
                onActionRow: onControlAction,
                onBlurRow: onControlBlur,
                onSend: { text in actions.sendText(snapshot.workstreamId, text) }
            )
        default:
            TelemetryActionArea(snapshot: snapshot)
        }
    }

    private var primaryTitle: String {
        switch snapshot.payload {
        case .permissionRequest(_, let toolName, _, _):
            return "\(snapshot.source.rawValue.capitalized) · \(toolName)"
        case .exitPlan:
            return "\(snapshot.source.rawValue.capitalized) · \(String(localized: "feed.kind.exitPlan", defaultValue: "Exit plan"))"
        case .question:
            return "\(snapshot.source.rawValue.capitalized) · \(String(localized: "feed.kind.question", defaultValue: "Question"))"
        default:
            if let title = snapshot.title, !title.isEmpty {
                return "\(snapshot.source.rawValue.capitalized) · \(title)"
            }
            return snapshot.source.rawValue.capitalized
        }
    }

    private var helpText: String {
        var lines: [String] = [primaryTitle]
        if let cwd = snapshot.cwd { lines.append(cwd) }
        lines.append(absoluteTime(snapshot.createdAt))
        return lines.joined(separator: "\n")
    }

    private func resolvedBadgeLabel(_ decision: WorkstreamDecision) -> String {
        let submitted = String(localized: "feed.badge.submitted", defaultValue: "Submitted")
        switch decision {
        case .permission(let m):
            return "\(submitted) · \(m.displayLabel)"
        case .exitPlan(let m, let feedback):
            if let feedback, !feedback.isEmpty {
                return "\(submitted) · " + String(localized: "feed.badge.refined", defaultValue: "refined")
            }
            return "\(submitted) · \(m.displayLabel)"
        case .question:
            return submitted
        }
    }

    private func statusTag(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(color.opacity(0.12))
            )
    }

    private func relativeTime(_ date: Date) -> String {
        Self.relativeFormatter.localizedString(for: date, relativeTo: Date())
    }

    private func absoluteTime(_ date: Date) -> String {
        Self.absoluteFormatter.string(from: date)
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    private static let absoluteFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()
}

// MARK: - Per-kind action areas

private struct FeedContextBlock: View {
    let context: WorkstreamContext
    let source: WorkstreamSource

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let user = context.lastUserMessage {
                FeedLabeledTextRow(
                    label: String(localized: "feed.context.you", defaultValue: "You:"),
                    text: user,
                    labelColor: .secondary,
                    textColor: .secondary
                )
            }
            if let preamble = context.assistantPreamble {
                FeedLabeledTextRow(
                    label: agentLabel,
                    text: preamble,
                    labelColor: .secondary,
                    textColor: .secondary,
                    rendersMarkdown: source == .claude
                )
            }
            if let plan = context.planSummary {
                FeedLabeledTextRow(
                    label: String(localized: "feed.context.plan", defaultValue: "Plan:"),
                    text: plan,
                    labelColor: Color.purple.opacity(0.85),
                    textColor: .secondary,
                    rendersMarkdown: source == .claude
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var agentLabel: String {
        "\(source.rawValue.capitalized):"
    }
}

struct FeedLabeledTextRow: View {
    let label: String
    let text: String
    let labelColor: Color
    let textColor: Color
    var rendersMarkdown: Bool = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(labelColor)
                .frame(width: 48, alignment: .leading)
            if rendersMarkdown {
                FeedMarkdownInlineText(
                    text: text,
                    fontSize: 11,
                    foregroundColor: textColor
                )
            } else {
                Text(text)
                    .font(.system(size: 11))
                    .foregroundColor(textColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private extension WorkstreamKind {
    var symbolName: String {
        switch self {
        case .permissionRequest: return "lock.shield"
        case .exitPlan: return "list.bullet.rectangle"
        case .question: return "questionmark.circle"
        case .toolUse, .toolResult: return "terminal"
        case .userPrompt: return "person"
        case .assistantMessage: return "sparkles"
        case .sessionStart, .sessionEnd: return "play.circle"
        case .stop: return "stop.circle"
        case .todos: return "checklist"
        }
    }
}
