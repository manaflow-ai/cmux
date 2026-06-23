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
    @State private var isEmptyAddComposerActive = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title)
                    .cmuxFont(size: 13, weight: .semibold)
                    .foregroundStyle(.primary)
                Text(tasks.count, format: .number)
                    .cmuxFont(.caption)
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 2)
            .padding(.top, canArchive ? 0 : 4)

            if tasks.isEmpty {
                emptyState
            } else {
                VStack(spacing: 0) {
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
            WorkspaceTaskInsertionDividerView(
                style: .append,
                isActive: isEmptyAddComposerActive,
                allowsAdd: true,
                draft: $addDraft,
                activate: {
                    addDraft = ""
                    isEmptyAddComposerActive = true
                },
                cancel: {
                    addDraft = ""
                    isEmptyAddComposerActive = false
                },
                submit: {
                    guard submitAddDraft() else { return }
                    isEmptyAddComposerActive = false
                },
                dropTask: { _ in false }
            )
            .padding(.top, 4)
        } else {
            Text(emptyText)
                .cmuxFont(.caption)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 2)
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

    @discardableResult
    private func submitAddDraft() -> Bool {
        guard actions.add(addDraft, nil) else { return false }
        addDraft = ""
        return true
    }
}
