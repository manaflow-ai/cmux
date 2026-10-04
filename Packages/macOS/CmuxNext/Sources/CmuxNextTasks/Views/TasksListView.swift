import SwiftUI

/// Variant `list`: dense rows grouped by status, in workflow order.
struct TasksListView: View {
    let model: TasksModel
    @Environment(\.tasksColors) private var colors

    var body: some View {
        let tasks = model.shownTasks
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1, pinnedViews: [.sectionHeaders]) {
                ForEach(model.statuses.filter { $0.category != .canceled }) { status in
                    let rows = tasks.filter { $0.status == status.id }
                    if !rows.isEmpty {
                        Section {
                            ForEach(rows) { task in
                                TaskRow(task: task, model: model, selected: model.selection == task.id, showStatus: false)
                            }
                        } header: {
                            StatusHeader(status: status, count: rows.count)
                        }
                    }
                }
                if tasks.isEmpty {
                    Text(TasksStrings.empty).font(.system(size: 12)).foregroundStyle(colors.tertiary)
                        .frame(maxWidth: .infinity).padding(.top, 60)
                }
            }
            .padding(.horizontal, 8).padding(.bottom, 12)
        }
    }
}

struct StatusHeader: View {
    let status: TaskStatusItem
    let count: Int
    @Environment(\.tasksColors) private var colors

    var body: some View {
        HStack(spacing: 7) {
            StatusGlyph(category: status.category, color: colors.ansi(status.color))
            Text(status.name).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(colors.secondary)
            Text("\(count)").font(.system(size: 11)).foregroundStyle(colors.tertiary)
            Spacer()
        }
        .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 4)
        .background(colors.surface)
    }
}
