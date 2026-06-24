public import AppKit
public import CMUXAgentLaunch
public import SwiftUI

// MARK: - Row (matches SessionIndexView row aesthetic)

/// A single feed card: a compact header (kind icon, project/path title, source
/// and age chips), optional context/prompt-echo block, and a kind-specific
/// action area (permission, exit plan, question, stop, or telemetry).
///
/// The row holds only the immutable ``FeedItemSnapshot`` plus the
/// ``FeedRowActions`` closure bundle and two focus-seam closures, so it never
/// references the feed store (the snapshot-boundary rule). It is `Equatable`
/// and `.equatable()`-wrapped at its call site so an orthogonal store change
/// cannot re-evaluate every row's body.
public struct FeedItemRow: View, Equatable {
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
    /// Focus seam for the question/stop inline reply fields: ask the app to move
    /// keyboard focus to the Feed right-sidebar host for a window, returning
    /// whether it did.
    let moveFocusToFeedHost: @MainActor (NSWindow) -> Bool
    /// Focus seam for the question/stop inline reply fields: report whether a
    /// window's new first responder still belongs to the Feed focus domain.
    let responderRetainsFeedFocus: (NSResponder) -> Bool

    @State private var didHandlePressSelection = false

    /// Creates a feed card for a snapshot.
    /// - Parameters:
    ///   - snapshot: Immutable projection of the source item.
    ///   - actions: Closure bundle delivering the user's decisions to the app.
    ///   - isSelected: Whether the row is the keyboard-focused selection.
    ///   - onPressSelect: Invoked on first press to select the row.
    ///   - onControlFocus: Invoked when an inline control gains focus.
    ///   - onControlAction: Invoked before an inline control acts on the row.
    ///   - onControlBlur: Invoked when an inline control loses focus.
    ///   - onActivate: Invoked on double-tap to activate the row.
    ///   - stopDraft: Binding to the in-progress stop-reply text.
    ///   - stopDraftValue: Snapshot of the stop-reply text for equality diffing.
    ///   - stopFocusRequest: Binding to the stop-reply focus-request counter.
    ///   - stopFocusRequestValue: Snapshot of the focus-request counter for
    ///     equality diffing.
    ///   - moveFocusToFeedHost: Focus seam moving keyboard focus to the Feed
    ///     sidebar host for a window.
    ///   - responderRetainsFeedFocus: Focus seam reporting whether a responder
    ///     still belongs to the Feed focus domain.
    public init(
        snapshot: FeedItemSnapshot,
        actions: FeedRowActions,
        isSelected: Bool,
        onPressSelect: @escaping () -> Void,
        onControlFocus: @escaping () -> Void,
        onControlAction: @escaping () -> Void,
        onControlBlur: @escaping () -> Void,
        onActivate: @escaping () -> Void,
        stopDraft: Binding<FeedStopDraft>,
        stopDraftValue: FeedStopDraft,
        stopFocusRequest: Binding<Int>,
        stopFocusRequestValue: Int,
        moveFocusToFeedHost: @escaping @MainActor (NSWindow) -> Bool,
        responderRetainsFeedFocus: @escaping (NSResponder) -> Bool
    ) {
        self.snapshot = snapshot
        self.actions = actions
        self.isSelected = isSelected
        self.onPressSelect = onPressSelect
        self.onControlFocus = onControlFocus
        self.onControlAction = onControlAction
        self.onControlBlur = onControlBlur
        self.onActivate = onActivate
        self._stopDraft = stopDraft
        self.stopDraftValue = stopDraftValue
        self._stopFocusRequest = stopFocusRequest
        self.stopFocusRequestValue = stopFocusRequestValue
        self.moveFocusToFeedHost = moveFocusToFeedHost
        self.responderRetainsFeedFocus = responderRetainsFeedFocus
    }

    public static func == (lhs: FeedItemRow, rhs: FeedItemRow) -> Bool {
        lhs.snapshot == rhs.snapshot
            && lhs.isSelected == rhs.isSelected
            && lhs.stopDraftValue == rhs.stopDraftValue
            && lhs.stopFocusRequestValue == rhs.stopFocusRequestValue
    }

    public var body: some View {
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
            return String(localized: "feed.promptEcho", defaultValue: "You: \(echo)", bundle: .main)
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
            return String(localized: "feed.kind.permission", defaultValue: "PERMISSION", bundle: .main)
        case .exitPlan:
            return String(localized: "feed.kind.plan", defaultValue: "PLAN", bundle: .main)
        case .question:
            return String(localized: "feed.kind.question.upper", defaultValue: "QUESTION", bundle: .main)
        case .toolUse:
            return String(localized: "feed.kind.toolUse", defaultValue: "TOOL USE", bundle: .main)
        case .toolResult:
            return String(localized: "feed.kind.toolResult", defaultValue: "TOOL RESULT", bundle: .main)
        case .userPrompt:
            return String(localized: "feed.kind.prompt", defaultValue: "PROMPT", bundle: .main)
        case .assistantMessage:
            return String(localized: "feed.kind.message", defaultValue: "MESSAGE", bundle: .main)
        case .sessionStart:
            return String(localized: "feed.kind.sessionStart.upper", defaultValue: "SESSION START", bundle: .main)
        case .sessionEnd:
            return String(localized: "feed.kind.sessionEnd.upper", defaultValue: "SESSION END", bundle: .main)
        case .stop:
            return String(localized: "feed.kind.stop", defaultValue: "STOP", bundle: .main)
        case .todos:
            return String(localized: "feed.kind.todos", defaultValue: "TODOS", bundle: .main)
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
                },
                moveFocusToFeedHost: moveFocusToFeedHost,
                responderRetainsFeedFocus: responderRetainsFeedFocus
            )
        case .stop:
            StopActionArea(
                draft: $stopDraft,
                focusRequest: $stopFocusRequest,
                onFocusRow: onControlFocus,
                onActionRow: onControlAction,
                onBlurRow: onControlBlur,
                onSend: { text in actions.sendText(snapshot.workstreamId, text) },
                moveFocusToFeedHost: moveFocusToFeedHost,
                responderRetainsFeedFocus: responderRetainsFeedFocus
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
            return "\(snapshot.source.rawValue.capitalized) · \(String(localized: "feed.kind.exitPlan", defaultValue: "Exit plan", bundle: .main))"
        case .question:
            return "\(snapshot.source.rawValue.capitalized) · \(String(localized: "feed.kind.question", defaultValue: "Question", bundle: .main))"
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
        let submitted = String(localized: "feed.badge.submitted", defaultValue: "Submitted", bundle: .main)
        switch decision {
        case .permission(let m):
            return "\(submitted) · \(m.displayLabel)"
        case .exitPlan(let m, let feedback):
            if let feedback, !feedback.isEmpty {
                return "\(submitted) · " + String(localized: "feed.badge.refined", defaultValue: "refined", bundle: .main)
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
