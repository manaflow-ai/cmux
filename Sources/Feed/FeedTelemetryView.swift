import AppKit
import CMUXAgentLaunch
import CmuxFoundation
import Foundation
import SwiftUI

struct StopActionArea: View {
    @Binding var draft: FeedStopDraft
    @Binding var focusRequest: Int

    let onFocusRow: () -> Void
    let onActionRow: () -> Void
    let onBlurRow: () -> Void
    let onSend: (String) -> Void

    private var trimmed: String {
        draft.reply.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private var canSend: Bool { !trimmed.isEmpty }
    @Environment(\.cmuxGlobalFontMagnificationPercent) private var globalFontPercent
    private var replyFont: NSFont { GlobalFontMagnification.systemFont(ofSize: 12) }
    private var replyBinding: Binding<String> {
        Binding(
            get: { draft.reply },
            set: { draft.reply = $0 }
        )
    }

    var body: some View {
        let _ = globalFontPercent
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: "checkmark.circle")
                    .cmuxFont(size: 10)
                    .foregroundColor(.secondary)
                Text(String(localized: "feed.stop.label", defaultValue: "Claude finished — reply to continue"))
                    .cmuxFont(size: 11, weight: .medium)
                    .foregroundColor(.secondary)
            }
            FeedInlineTextField(
                text: replyBinding,
                focusRequest: focusRequest == 0 ? nil : focusRequest,
                placeholder: String(localized: "feed.stop.placeholder", defaultValue: "Reply to Claude…"),
                isEnabled: true,
                font: replyFont,
                onFocus: onFocusRow,
                onBlur: onBlurRow,
                onSubmit: sendReply
            )
            .frame(
                maxWidth: .infinity,
                minHeight: FeedInlineTextEditorView.minimumHeight(for: replyFont),
                alignment: .leading
            )
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Color.primary.opacity(canSend ? 0.25 : 0.10), lineWidth: 1)
            )
            .contentShape(Rectangle())
            .feedIBeamCursorOnHover(enabled: true)
            .onTapGesture {
                onFocusRow()
                requestReplyFocus()
            }
            FeedButton(
                label: String(localized: "feed.stop.send", defaultValue: "Send to Claude"),
                leadingIcon: "arrow.up.circle.fill",
                kind: canSend ? .primary : .soft,
                size: .medium,
                fullWidth: true,
                dimmed: !canSend
            ) {
                guard canSend else { return }
                onActionRow()
                sendReply()
            }
        }
    }

    private func requestReplyFocus() {
        focusRequest += 1
    }

    private func sendReply() {
        guard canSend else { return }
        onSend(trimmed)
        draft.reply = ""
    }
}

struct TelemetryActionArea: View {
    let snapshot: FeedItemSnapshot

    var body: some View {
        if case .todos(let todos) = snapshot.payload {
            TodoListBody(todos: todos)
        } else if case .assistantMessage(let text) = snapshot.payload,
                  snapshot.source == .claude {
            FeedMarkdownInlineText(
                text: text,
                fontSize: 11,
                foregroundColor: .secondary.opacity(0.85)
            )
            .lineLimit(3)
            .truncationMode(.tail)
        } else if !summary.isEmpty {
            Text(summary)
                .cmuxFont(size: 11, design: .monospaced)
                .foregroundColor(.secondary.opacity(0.85))
                .lineLimit(3)
                .truncationMode(.tail)
        }
    }

    private var summary: String {
        switch snapshot.payload {
        case .toolUse(let name, let json):
            return "\(name) \(json)"
        case .toolResult(let name, let json, let err):
            let status = err
                ? String(localized: "feed.telemetry.error", defaultValue: "error")
                : String(localized: "feed.telemetry.ok", defaultValue: "ok")
            return "\(name) \(status) \(json)"
        case .userPrompt(let text), .assistantMessage(let text):
            return text
        case .sessionStart:
            return String(localized: "feed.telemetry.sessionStart", defaultValue: "session start")
        case .sessionEnd:
            return String(localized: "feed.telemetry.sessionEnd", defaultValue: "session end")
        case .stop(let reason):
            let label = String(localized: "feed.telemetry.stop", defaultValue: "stop")
            guard let reason, !reason.isEmpty else { return label }
            return "\(label) \(reason)"
        default:
            return ""
        }
    }
}

private struct TodoListBody: View {
    let todos: [WorkstreamTaskTodo]

    @State private var expanded = false

    private var done: [WorkstreamTaskTodo] { todos.filter { $0.state == .completed } }
    private var inProgress: [WorkstreamTaskTodo] { todos.filter { $0.state == .inProgress } }
    private var pending: [WorkstreamTaskTodo] { todos.filter { $0.state == .pending } }

    private var visibleDone: [WorkstreamTaskTodo] {
        expanded ? done : Array(done.prefix(2))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Text(String(localized: "feed.todos.title", defaultValue: "Tasks"))
                    .cmuxFont(size: 11, weight: .semibold)
                    .foregroundColor(.primary.opacity(0.9))
                Text(summaryLabel)
                    .cmuxFont(size: 10)
                    .foregroundColor(.secondary)
            }
            VStack(alignment: .leading, spacing: 3) {
                ForEach(inProgress, id: \.id) { row($0) }
                ForEach(pending, id: \.id) { row($0) }
                ForEach(visibleDone, id: \.id) { row($0) }
                if done.count > visibleDone.count {
                    Button {
                        expanded.toggle()
                    } label: {
                        Text(String(
                            localized: "feed.todos.moreCompleted",
                            defaultValue: "... +\(done.count - visibleDone.count) completed"
                        ))
                            .cmuxFont(size: 11)
                            .foregroundColor(.secondary.opacity(0.8))
                            .padding(.leading, 22)
                    }
                    .buttonStyle(.plain)
                }
                if expanded && done.count > 2 {
                    Button { expanded = false } label: {
                        Text(String(localized: "feed.todos.collapse", defaultValue: "Collapse"))
                            .cmuxFont(size: 11)
                            .foregroundColor(.secondary.opacity(0.8))
                            .padding(.leading, 22)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var summaryLabel: String {
        let d = done.count, ip = inProgress.count, p = pending.count
        var parts: [String] = []
        if d > 0 {
            parts.append(String(localized: "feed.todos.summary.done", defaultValue: "\(d) done"))
        }
        if ip > 0 {
            parts.append(String(localized: "feed.todos.summary.inProgress", defaultValue: "\(ip) in progress"))
        }
        if p > 0 {
            parts.append(String(localized: "feed.todos.summary.open", defaultValue: "\(p) open"))
        }
        return "(" + parts.joined(separator: ", ") + ")"
    }

    @ViewBuilder
    private func row(_ todo: WorkstreamTaskTodo) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: symbol(for: todo.state))
                .cmuxFont(size: 11, weight: .medium)
                .foregroundColor(color(for: todo.state))
                .frame(width: 14, height: 14)
            Text(todo.content)
                .cmuxFont(size: 12)
                .foregroundColor(todo.state == .completed
                    ? .secondary.opacity(0.7)
                    : .primary.opacity(0.9))
                .strikethrough(todo.state == .completed, color: .secondary.opacity(0.6))
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
    }

    private func symbol(for state: WorkstreamTaskTodo.State) -> String {
        switch state {
        case .completed: return "checkmark.square.fill"
        case .inProgress: return "circle.fill"
        case .pending: return "square"
        }
    }

    private func color(for state: WorkstreamTaskTodo.State) -> Color {
        switch state {
        case .completed: return .secondary.opacity(0.7)
        case .inProgress: return .blue
        case .pending: return .secondary
        }
    }
}

/// Dashed separator between pending items and resolved ones.
private struct ResolvedDivider: View {
    var body: some View {
        HStack(spacing: 8) {
            line
            Text(String(localized: "feed.divider.resolved", defaultValue: "Resolved"))
                .cmuxFont(size: 10, weight: .medium)
                .tracking(0.5)
                .foregroundColor(.secondary.opacity(0.7))
            line
        }
        .padding(.vertical, 2)
    }

    private var line: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.08))
            .frame(height: 1)
    }
}

// MARK: - Kind → SF Symbol

extension WorkstreamKind {
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
