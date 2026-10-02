import SwiftUI

/// Variant `inbox`: what needs a person first (agent waiting, ready for
/// review, agent failed, assigned to me), then the rest; detail on the right.
struct TasksInboxView: View {
    let model: TasksModel
    @Environment(\.tasksColors) private var colors

    var body: some View {
        let groups = InboxGroups(tasks: model.visibleTasks, me: model.me?.stableID)
        HStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    section(TasksStrings.needsInput, groups.needsInput)
                    section(TasksStrings.review, groups.review)
                    section(TasksStrings.failed, groups.failed)
                    section(TasksStrings.mine, groups.mine)
                    section(TasksStrings.rest, groups.rest)
                    if groups.needsInput.isEmpty && groups.review.isEmpty && groups.failed.isEmpty {
                        Text(TasksStrings.inboxZero).font(.system(size: 11.5)).foregroundStyle(colors.tertiary)
                            .padding(.horizontal, 12).padding(.top, 4)
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 6)
            }
            .frame(minWidth: 320, idealWidth: 460)
            Rectangle().fill(colors.separator).frame(width: 1)
            Group {
                if let id = model.selection ?? groups.first?.id, let task = model.visibleTasks.first(where: { $0.id == id }) {
                    TaskDetailView(task: task, model: model)
                } else {
                    Color.clear
                }
            }
            .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func section(_ title: String, _ tasks: [TaskItem]) -> some View {
        if !tasks.isEmpty {
            HStack(spacing: 6) {
                Text(title).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(colors.secondary)
                Text("\(tasks.count)").font(.system(size: 11)).foregroundStyle(colors.tertiary)
            }
            .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 4)
            ForEach(tasks) { task in
                TaskRow(task: task, model: model, selected: (model.selection ?? "") == task.id)
            }
        }
    }
}

/// Inbox partition: every visible open task lands in exactly one group.
struct InboxGroups {
    var needsInput: [TaskItem] = []
    var review: [TaskItem] = []
    var failed: [TaskItem] = []
    var mine: [TaskItem] = []
    var rest: [TaskItem] = []

    init(tasks: [TaskItem], me: String?) {
        let open = tasks.filter { $0.category.isOpen }.sorted { ($0.priority.rank, -$0.updatedAt) < ($1.priority.rank, -$1.updatedAt) }
        for task in open {
            switch task.attention {
            case .needsInput: needsInput.append(task)
            case .review: review.append(task)
            case .failed: failed.append(task)
            case nil:
                if let me, task.assignee?.stableID == me { mine.append(task) } else { rest.append(task) }
            }
        }
    }

    var first: TaskItem? { (needsInput + review + failed + mine + rest).first }
}
