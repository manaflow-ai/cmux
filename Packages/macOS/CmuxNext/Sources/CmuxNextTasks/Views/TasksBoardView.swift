import SwiftUI

/// Variant `board`: a column per status; dragging a card to another column
/// sends one `task.update` intent (the drag itself is local gesture state).
struct TasksBoardView: View {
    let model: TasksModel
    @Environment(\.tasksColors) private var colors

    var body: some View {
        let tasks = model.shownTasks
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 10) {
                ForEach(model.statuses.filter { $0.category != .canceled }) { status in
                    BoardColumn(status: status, tasks: tasks.filter { $0.status == status.id }, model: model)
                }
            }
            .padding(12)
        }
    }
}

private struct BoardColumn: View {
    let status: TaskStatusItem
    let tasks: [TaskItem]
    let model: TasksModel
    @Environment(\.tasksColors) private var colors
    @State private var targeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                StatusGlyph(category: status.category, color: colors.ansi(status.color))
                Text(status.name).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(colors.secondary)
                Text("\(tasks.count)").font(.system(size: 11)).foregroundStyle(colors.tertiary)
                Spacer()
            }
            .padding(.horizontal, 4).padding(.bottom, 2)
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(tasks) { task in
                        BoardCard(task: task, model: model).draggable(task.id)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(6)
        .frame(width: TasksTunables.boardColumnWidth.value)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 10).fill(targeted ? colors.hover : colors.hover.opacity(0.35)))
        .dropDestination(for: String.self) { ids, _ in
            for id in ids { model.setStatus(id, to: status.id) }
            return !ids.isEmpty
        } isTargeted: { targeted = $0 }
    }
}

private struct BoardCard: View {
    let task: TaskItem
    let model: TasksModel
    @Environment(\.tasksColors) private var colors
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Text(task.key).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(colors.tertiary)
                AttentionDot(attention: task.attention)
                Spacer()
                AssigneeBadge(assignee: task.assignee, delegate: task.delegate, size: 16)
            }
            Text(task.title).font(.system(size: 12.5)).foregroundStyle(colors.primary)
                .lineLimit(3).fixedSize(horizontal: false, vertical: true)
            if let session = model.session(for: task.id), !session.plan.isEmpty {
                PlanProgress(session: session)
            }
            HStack(spacing: 6) {
                PriorityGlyph(priority: task.priority)
                LabelChips(labels: task.labels.compactMap { model.labels[$0] })
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(model.selection == task.id ? colors.selection : colors.elevated)
                .shadow(color: colors.shadow.opacity(hovering ? 0.6 : 0.3), radius: hovering ? 5 : 2, y: 1)
        )
        .opacity(model.isPending(task.id) ? 0.6 : 1)
        .onHover { hovering = $0 }
        .onTapGesture { model.selection = task.id }
        .contextMenu { TaskContextMenu(task: task, model: model) }
    }
}
