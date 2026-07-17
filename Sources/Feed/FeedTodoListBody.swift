import AppKit
import CMUXAgentLaunch
import CmuxFoundation
import Foundation
import SwiftUI

struct TodoListBody: View {
    let todos: [WorkstreamTaskTodo]
    private let done: [WorkstreamTaskTodo]
    private let inProgress: [WorkstreamTaskTodo]
    private let pending: [WorkstreamTaskTodo]

    @State private var expanded = false

    init(todos: [WorkstreamTaskTodo]) {
        self.todos = todos
        var done: [WorkstreamTaskTodo] = []
        var inProgress: [WorkstreamTaskTodo] = []
        var pending: [WorkstreamTaskTodo] = []
        for todo in todos {
            switch todo.state {
            case .completed: done.append(todo)
            case .inProgress: inProgress.append(todo)
            case .pending: pending.append(todo)
            }
        }
        self.done = done
        self.inProgress = inProgress
        self.pending = pending
    }

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
                        Text(moreCompletedLabel(done.count - visibleDone.count))
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
            parts.append(doneLabel(d))
        }
        if ip > 0 {
            parts.append(inProgressLabel(ip))
        }
        if p > 0 {
            parts.append(openLabel(p))
        }
        return "(" + parts.joined(separator: ", ") + ")"
    }

    private func moreCompletedLabel(_ count: Int) -> String {
        if count == 1 {
            return String(localized: "feed.todos.moreCompleted.one", defaultValue: "... +1 completed")
        }
        return String(
            localized: "feed.todos.moreCompleted.other",
            defaultValue: "... +\(count) completed"
        )
    }

    private func doneLabel(_ count: Int) -> String {
        if count == 1 {
            return String(localized: "feed.todos.summary.done.one", defaultValue: "1 done")
        }
        return String(localized: "feed.todos.summary.done.other", defaultValue: "\(count) done")
    }

    private func inProgressLabel(_ count: Int) -> String {
        if count == 1 {
            return String(
                localized: "feed.todos.summary.inProgress.one",
                defaultValue: "1 in progress"
            )
        }
        return String(
            localized: "feed.todos.summary.inProgress.other",
            defaultValue: "\(count) in progress"
        )
    }

    private func openLabel(_ count: Int) -> String {
        if count == 1 {
            return String(localized: "feed.todos.summary.open.one", defaultValue: "1 open")
        }
        return String(localized: "feed.todos.summary.open.other", defaultValue: "\(count) open")
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
