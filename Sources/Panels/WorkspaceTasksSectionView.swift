import SwiftUI

struct WorkspaceTasksSectionView: View {
    let title: String
    let emptyText: String
    let tasks: [WorkspaceTask]
    let canArchive: Bool
    @Binding var addDraft: String
    @Binding var insertionAfterTaskId: UUID?
    @Binding var insertionDraft: String
    let actions: WorkspaceTasksActions

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .cmuxFont(size: 12, weight: .semibold)
                .foregroundStyle(.secondary)
            if tasks.isEmpty {
                emptyState
            } else {
                VStack(spacing: 4) {
                    dropDivider(beforeTaskId: tasks.first?.id, afterTaskId: nil, index: 0, style: .leadingDrop)
                    ForEach(Array(tasks.enumerated()), id: \.element.id) { index, task in
                        WorkspaceTaskRowView(
                            task: task,
                            canArchive: canArchive,
                            canMoveUp: index > 0,
                            canMoveDown: index < tasks.count - 1,
                            archive: { actions.archive(task.id) },
                            unarchive: { actions.unarchive(task.id) },
                            remove: { actions.remove(task.id) },
                            moveUp: { actions.move(task.id, nil, nil, index - 1) },
                            moveDown: { actions.move(task.id, nil, nil, index + 1) }
                        )
                        .draggable(task.id.uuidString)

                        dropDivider(
                            beforeTaskId: index < tasks.count - 1 ? tasks[index + 1].id : nil,
                            afterTaskId: task.id,
                            index: index + 1,
                            style: canArchive && index == tasks.count - 1 ? .append : .hoverInsert
                        )
                    }
                }
            }
        }
        .animation(listAnimation, value: tasks.map(\.id))
    }

    @ViewBuilder
    private var emptyState: some View {
        if canArchive {
            WorkspaceTaskAddComposer(
                draft: $addDraft,
                placeholder: String(localized: "workspaceTasks.add.placeholder", defaultValue: "Add a task"),
                submitLabel: String(localized: "workspaceTasks.add.label", defaultValue: "Add task"),
                submit: submitAddDraft
            )
        } else {
            Text(emptyText)
                .cmuxFont(.caption)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
        }
    }

    private var listAnimation: Animation? {
        reduceMotion ? nil : .easeInOut(duration: 0.16)
    }

    private func dropDivider(
        beforeTaskId: UUID?,
        afterTaskId: UUID?,
        index: Int,
        style: WorkspaceTaskInsertionDividerView.Style
    ) -> some View {
        WorkspaceTaskInsertionDividerView(
            style: style,
            isActive: canArchive && style != .leadingDrop && insertionAfterTaskId == afterTaskId,
            allowsAdd: canArchive && style != .leadingDrop,
            draft: $insertionDraft,
            activate: {
                guard canArchive, style != .leadingDrop, let afterTaskId else { return }
                insertionDraft = ""
                insertionAfterTaskId = afterTaskId
            },
            cancel: {
                insertionDraft = ""
                insertionAfterTaskId = nil
            },
            submit: {
                let draft = insertionDraft
                guard let afterTaskId, actions.add(draft, afterTaskId) else { return }
                insertionDraft = ""
                insertionAfterTaskId = nil
            },
            dropTask: { taskIdString in
                guard let taskId = UUID(uuidString: taskIdString),
                      tasks.contains(where: { $0.id == taskId })
                else { return false }
                actions.move(taskId, beforeTaskId, beforeTaskId == nil ? afterTaskId : nil, index)
                return true
            }
        )
    }

    private func submitAddDraft() {
        guard actions.add(addDraft, nil) else { return }
        addDraft = ""
    }
}
