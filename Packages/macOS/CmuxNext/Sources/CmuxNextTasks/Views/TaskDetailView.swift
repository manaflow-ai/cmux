import SwiftUI

/// The selected task: title, status, agent session with its plan.
struct TaskDetailView: View {
    let task: TaskItem
    let model: TasksModel
    @Environment(\.tasksColors) private var colors

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    Text(task.key).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(colors.tertiary)
                    if let status = model.status(task.status) {
                        Menu {
                            StatusMenu(task: task, model: model)
                        } label: {
                            HStack(spacing: 5) {
                                StatusGlyph(category: status.category, color: colors.ansi(status.color))
                                Text(status.name).font(.system(size: 11.5)).foregroundStyle(colors.secondary)
                            }
                        }
                        .menuStyle(.button).buttonStyle(.plain).fixedSize()
                    }
                    PriorityGlyph(priority: task.priority)
                    Spacer()
                    AssigneeBadge(assignee: task.assignee, delegate: task.delegate)
                }
                Text(task.title).font(.system(size: 17, weight: .semibold)).foregroundStyle(colors.primary)
                    .fixedSize(horizontal: false, vertical: true)
                LabelChips(labels: task.labels.compactMap { model.labels[$0] })
                if let session = model.session(for: task.id) {
                    SessionCard(session: session)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct SessionCard: View {
    let session: TaskSessionItem
    @Environment(\.tasksColors) private var colors

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "sparkle").font(.system(size: 11, weight: .semibold)).foregroundStyle(colors.ansi(5))
                Text(session.agent.harness).font(.system(size: 12, weight: .medium)).foregroundStyle(colors.primary)
                Text(TasksStrings.session(session.status)).font(.system(size: 11.5)).foregroundStyle(statusColor)
                Spacer()
            }
            if !session.plan.isEmpty {
                Text(TasksStrings.plan).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(colors.tertiary)
                ForEach(Array(session.plan.enumerated()), id: \.offset) { _, step in
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Image(systemName: symbol(step.status)).font(.system(size: 10.5)).foregroundStyle(step.status == "completed" ? colors.success : colors.tertiary)
                        Text(step.content).font(.system(size: 12)).foregroundStyle(step.status == "completed" ? colors.secondary : colors.primary)
                    }
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 9).fill(colors.hover.opacity(0.5)))
    }

    private var statusColor: Color {
        switch session.status {
        case .awaitingInput: colors.attention
        case .failed: colors.danger
        case .done: colors.success
        default: colors.tertiary
        }
    }

    private func symbol(_ status: String) -> String {
        switch status {
        case "completed": "checkmark.circle.fill"
        case "in_progress": "circle.dotted"
        default: "circle"
        }
    }
}
