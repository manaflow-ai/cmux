import Foundation
import CMUXAgentLaunch
import SwiftUI

/// Renders an agent's `TodoWrite` task list: in-progress and pending rows first,
/// completed rows collapsed to two with an expand/collapse control, plus a
/// header summarizing the done/in-progress/open counts.
struct TodoListBody: View {
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
                Text(String(localized: "feed.todos.title", defaultValue: "Tasks", bundle: .main))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.primary.opacity(0.9))
                Text(summaryLabel)
                    .font(.system(size: 10))
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
                            defaultValue: "... +\(done.count - visibleDone.count) completed",
                            bundle: .main
                        ))
                            .font(.system(size: 11))
                            .foregroundColor(.secondary.opacity(0.8))
                            .padding(.leading, 22)
                    }
                    .buttonStyle(.plain)
                }
                if expanded && done.count > 2 {
                    Button { expanded = false } label: {
                        Text(String(localized: "feed.todos.collapse", defaultValue: "Collapse", bundle: .main))
                            .font(.system(size: 11))
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
            parts.append(String(localized: "feed.todos.summary.done", defaultValue: "\(d) done", bundle: .main))
        }
        if ip > 0 {
            parts.append(String(localized: "feed.todos.summary.inProgress", defaultValue: "\(ip) in progress", bundle: .main))
        }
        if p > 0 {
            parts.append(String(localized: "feed.todos.summary.open", defaultValue: "\(p) open", bundle: .main))
        }
        return "(" + parts.joined(separator: ", ") + ")"
    }

    @ViewBuilder
    private func row(_ todo: WorkstreamTaskTodo) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: symbol(for: todo.state))
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(color(for: todo.state))
                .frame(width: 14, height: 14)
            Text(todo.content)
                .font(.system(size: 12))
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
