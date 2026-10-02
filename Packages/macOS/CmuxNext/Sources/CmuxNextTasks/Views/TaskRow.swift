import SwiftUI

/// One dense row (list and inbox).
struct TaskRow: View {
    let task: TaskItem
    let model: TasksModel
    var selected = false
    var showStatus = true
    @Environment(\.tasksColors) private var colors
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 9) {
            PriorityGlyph(priority: task.priority)
            Text(task.key)
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(colors.tertiary)
                .frame(minWidth: 46, alignment: .leading)
            if showStatus, let status = model.status(task.status) {
                StatusGlyph(category: status.category, color: colors.ansi(status.color))
                    .help(status.name)
            }
            Text(task.title)
                .font(.system(size: 12.5)).foregroundStyle(colors.primary)
                .lineLimit(1)
            AttentionDot(attention: task.attention)
            Spacer(minLength: 8)
            LabelDots(labels: task.labels.compactMap { model.labels[$0] })
            AssigneeBadge(assignee: task.assignee, delegate: task.delegate)
        }
        .padding(.horizontal, 12)
        .frame(height: TasksTunables.rowHeight.value)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(selected ? colors.selection : (hovering ? colors.hover : .clear))
        )
        .opacity(model.isPending(task.id) ? 0.6 : 1)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { model.selection = task.id }
        .contextMenu { StatusMenu(task: task, model: model) }
    }
}

/// Status choices for a task (right-click, detail).
struct StatusMenu: View {
    let task: TaskItem
    let model: TasksModel

    var body: some View {
        ForEach(model.statuses) { status in
            Button(status.name) { model.setStatus(task.id, to: status.id) }
                .disabled(status.id == task.status)
        }
    }
}
