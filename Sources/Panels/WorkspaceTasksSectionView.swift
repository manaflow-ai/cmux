import SwiftUI

struct WorkspaceTasksSectionView: View {
    let title: String
    let emptyText: String
    let tasks: [WorkspaceTask]
    let canArchive: Bool
    @Binding var insertionAfterTaskId: UUID?
    @Binding var insertionDraft: String
    let actions: WorkspaceTasksActions

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .cmuxFont(size: 12, weight: .semibold)
                .foregroundStyle(.secondary)
            if tasks.isEmpty {
                Text(emptyText)
                    .cmuxFont(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
            } else {
                VStack(spacing: 4) {
                    ForEach(Array(tasks.enumerated()), id: \.element.id) { index, task in
                        WorkspaceTaskRowView(
                            task: task,
                            canArchive: canArchive,
                            canMoveUp: index > 0,
                            canMoveDown: index < tasks.count - 1,
                            archive: { actions.archive(task.id) },
                            remove: { actions.remove(task.id) },
                            moveUp: { actions.move(task.id, index - 1) },
                            moveDown: { actions.move(task.id, index + 1) }
                        )
                        if canArchive, index < tasks.count - 1 {
                            WorkspaceTaskInsertionDividerView(
                                isActive: insertionAfterTaskId == task.id,
                                draft: $insertionDraft,
                                activate: {
                                    insertionDraft = ""
                                    insertionAfterTaskId = task.id
                                },
                                cancel: {
                                    insertionDraft = ""
                                    insertionAfterTaskId = nil
                                },
                                submit: {
                                    let draft = insertionDraft
                                    guard actions.add(draft, task.id) else { return }
                                    insertionDraft = ""
                                    insertionAfterTaskId = nil
                                }
                            )
                        }
                    }
                }
            }
        }
        .animation(.easeInOut(duration: 0.16), value: tasks.map(\.id))
    }
}
