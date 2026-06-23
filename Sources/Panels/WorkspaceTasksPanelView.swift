import CmuxSettingsUI
import SwiftUI

struct WorkspaceTasksPanelView: View {
    @ObservedObject var panel: WorkspaceTasksPanel
    @ObservedObject var workspace: Workspace
    let appearance: PanelAppearance
    let onRequestPanelFocus: () -> Void

    @State private var addDraft = ""
    @State private var insertionAfterTaskId: UUID?
    @State private var insertionDraft = ""
    @LiveSetting(\.betaFeatures.workspaceTasks) private var workspaceTasksBetaEnabled

    var body: some View {
        Group {
            if workspaceTasksBetaEnabled {
                WorkspaceTasksView(
                    openTasks: workspace.openWorkspaceTasks,
                    archivedTasks: workspace.archivedWorkspaceTasks,
                    addDraft: $addDraft,
                    insertionAfterTaskId: $insertionAfterTaskId,
                    insertionDraft: $insertionDraft,
                    showsOpenAsTabButton: false,
                    actions: actions
                )
            } else {
                WorkspaceTasksDisabledView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: appearance.backgroundColor))
        .simultaneousGesture(TapGesture().onEnded { requestPanelFocusIfNeeded() })
    }

    private var actions: WorkspaceTasksActions {
        WorkspaceTasksActions(
            add: { title, afterTaskId in
                withAnimation(.easeInOut(duration: 0.16)) {
                    workspace.addWorkspaceTask(title: title, after: afterTaskId) != nil
                }
            },
            archive: { taskId in
                withAnimation(.easeInOut(duration: 0.16)) {
                    _ = workspace.archiveWorkspaceTask(id: taskId)
                }
            },
            remove: { taskId in
                withAnimation(.easeInOut(duration: 0.16)) {
                    _ = workspace.removeWorkspaceTask(id: taskId)
                }
            },
            move: { taskId, index in
                withAnimation(.easeInOut(duration: 0.16)) {
                    _ = workspace.moveWorkspaceTask(id: taskId, index: index)
                }
            },
            openSurface: {}
        )
    }

    private func requestPanelFocusIfNeeded() {
        guard !panel.isFocusedInWorkspace else { return }
        onRequestPanelFocus()
    }
}

struct WorkspaceTasksPopoverView: View {
    @ObservedObject var workspace: Workspace
    let openSurface: () -> Void

    @State private var addDraft = ""
    @State private var insertionAfterTaskId: UUID?
    @State private var insertionDraft = ""
    @LiveSetting(\.betaFeatures.workspaceTasks) private var workspaceTasksBetaEnabled

    var body: some View {
        Group {
            if workspaceTasksBetaEnabled {
                WorkspaceTasksView(
                    openTasks: workspace.openWorkspaceTasks,
                    archivedTasks: workspace.archivedWorkspaceTasks,
                    addDraft: $addDraft,
                    insertionAfterTaskId: $insertionAfterTaskId,
                    insertionDraft: $insertionDraft,
                    showsOpenAsTabButton: true,
                    actions: actions
                )
            } else {
                WorkspaceTasksDisabledView()
            }
        }
        .frame(width: 380, height: 460)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var actions: WorkspaceTasksActions {
        WorkspaceTasksActions(
            add: { title, afterTaskId in
                withAnimation(.easeInOut(duration: 0.16)) {
                    workspace.addWorkspaceTask(title: title, after: afterTaskId) != nil
                }
            },
            archive: { taskId in
                withAnimation(.easeInOut(duration: 0.16)) {
                    _ = workspace.archiveWorkspaceTask(id: taskId)
                }
            },
            remove: { taskId in
                withAnimation(.easeInOut(duration: 0.16)) {
                    _ = workspace.removeWorkspaceTask(id: taskId)
                }
            },
            move: { taskId, index in
                withAnimation(.easeInOut(duration: 0.16)) {
                    _ = workspace.moveWorkspaceTask(id: taskId, index: index)
                }
            },
            openSurface: openSurface
        )
    }
}

private struct WorkspaceTasksDisabledView: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "checklist")
                .cmuxSymbolRasterSize(18)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(String(localized: "workspaceTasks.disabled.title", defaultValue: "Workspace Tasks is disabled"))
                .cmuxFont(size: 14, weight: .semibold)
            Text(String(
                localized: "workspaceTasks.disabled.detail",
                defaultValue: "Enable Workspace Tasks in Beta Features to manage this list."
            ))
            .cmuxFont(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}

private struct WorkspaceTasksActions {
    let add: (String, UUID?) -> Bool
    let archive: (UUID) -> Void
    let remove: (UUID) -> Void
    let move: (UUID, Int) -> Void
    let openSurface: () -> Void
}

private struct WorkspaceTasksView: View {
    let openTasks: [WorkspaceTask]
    let archivedTasks: [WorkspaceTask]
    @Binding var addDraft: String
    @Binding var insertionAfterTaskId: UUID?
    @Binding var insertionDraft: String
    let showsOpenAsTabButton: Bool
    let actions: WorkspaceTasksActions

    var body: some View {
        VStack(spacing: 0) {
            WorkspaceTasksHeaderView(
                openCount: openTasks.count,
                archivedCount: archivedTasks.count,
                showsOpenAsTabButton: showsOpenAsTabButton,
                openSurface: actions.openSurface
            )
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    WorkspaceTaskAddComposer(
                        draft: $addDraft,
                        placeholder: String(localized: "workspaceTasks.add.placeholder", defaultValue: "Add a task"),
                        submitLabel: String(localized: "workspaceTasks.add.label", defaultValue: "Add task"),
                        submit: { submitAddDraft(afterTaskId: nil) }
                    )
                    WorkspaceTasksSectionView(
                        title: String(localized: "workspaceTasks.open.title", defaultValue: "Open"),
                        emptyText: String(localized: "workspaceTasks.empty.open", defaultValue: "No open tasks"),
                        tasks: openTasks,
                        canArchive: true,
                        insertionAfterTaskId: $insertionAfterTaskId,
                        insertionDraft: $insertionDraft,
                        actions: actions
                    )
                    WorkspaceTasksSectionView(
                        title: String(localized: "workspaceTasks.archived.title", defaultValue: "Archived"),
                        emptyText: String(localized: "workspaceTasks.empty.archived", defaultValue: "No archived tasks"),
                        tasks: archivedTasks,
                        canArchive: false,
                        insertionAfterTaskId: .constant(nil),
                        insertionDraft: .constant(""),
                        actions: actions
                    )
                }
                .padding(16)
            }
        }
    }

    private func submitAddDraft(afterTaskId: UUID?) {
        let draft = afterTaskId == nil ? addDraft : insertionDraft
        guard actions.add(draft, afterTaskId) else { return }
        if afterTaskId == nil {
            addDraft = ""
        } else {
            insertionDraft = ""
            insertionAfterTaskId = nil
        }
    }
}

private struct WorkspaceTasksHeaderView: View {
    let openCount: Int
    let archivedCount: Int
    let showsOpenAsTabButton: Bool
    let openSurface: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checklist")
                .cmuxSymbolRasterSize(16)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: "workspaceTasks.surface.title", defaultValue: "Workspace Tasks"))
                    .cmuxFont(size: 14, weight: .semibold)
                Text(summary)
                    .cmuxFont(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if showsOpenAsTabButton {
                Button(action: openSurface) {
                    Image(systemName: "macwindow.badge.plus")
                        .cmuxSymbolRasterSize(14)
                        .frame(width: 26, height: 24)
                }
                .buttonStyle(.plain)
                .help(String(localized: "workspaceTasks.openAsTab.help", defaultValue: "Open as tab"))
                .accessibilityLabel(String(localized: "workspaceTasks.openAsTab.label", defaultValue: "Open Workspace Tasks as Tab"))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var summary: String {
        String(
            format: String(localized: "workspaceTasks.summary", defaultValue: "%d open, %d archived"),
            locale: .current,
            openCount,
            archivedCount
        )
    }
}

private struct WorkspaceTaskAddComposer: View {
    @Binding var draft: String
    let placeholder: String
    let submitLabel: String
    let submit: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            TextField(placeholder, text: $draft)
                .textFieldStyle(.roundedBorder)
                .onSubmit(submit)
            Button(action: submit) {
                Image(systemName: "plus")
                    .cmuxSymbolRasterSize(13)
                    .frame(width: 26, height: 24)
            }
            .buttonStyle(.borderedProminent)
            .disabled(WorkspaceTask.normalizedTitle(draft).isEmpty)
            .help(submitLabel)
            .accessibilityLabel(submitLabel)
        }
    }
}

private struct WorkspaceTasksSectionView: View {
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

private struct WorkspaceTaskRowView: View {
    let task: WorkspaceTask
    let canArchive: Bool
    let canMoveUp: Bool
    let canMoveDown: Bool
    let archive: () -> Void
    let remove: () -> Void
    let moveUp: () -> Void
    let moveDown: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if canArchive {
                Button(action: archive) {
                    Image(systemName: "checkmark.circle")
                        .cmuxSymbolRasterSize(14)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .help(String(localized: "workspaceTasks.complete.help", defaultValue: "Complete task"))
                .accessibilityLabel(String(localized: "workspaceTasks.complete.label", defaultValue: "Complete Task"))
            } else {
                Image(systemName: "archivebox")
                    .cmuxSymbolRasterSize(13)
                    .foregroundStyle(.tertiary)
                    .frame(width: 24, height: 24)
                    .accessibilityHidden(true)
            }

            Text(task.title)
                .cmuxFont(.body)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)

            WorkspaceTaskIconButton(
                systemName: "chevron.up",
                label: String(localized: "workspaceTasks.moveUp.label", defaultValue: "Move Task Up"),
                isDisabled: !canMoveUp,
                action: moveUp
            )
            WorkspaceTaskIconButton(
                systemName: "chevron.down",
                label: String(localized: "workspaceTasks.moveDown.label", defaultValue: "Move Task Down"),
                isDisabled: !canMoveDown,
                action: moveDown
            )
            WorkspaceTaskIconButton(
                systemName: "trash",
                label: String(localized: "workspaceTasks.remove.label", defaultValue: "Remove Task"),
                role: .destructive,
                action: remove
            )
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.72))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .stroke(Color(nsColor: .separatorColor).opacity(0.35), lineWidth: 1)
        }
    }
}

private struct WorkspaceTaskInsertionDividerView: View {
    let isActive: Bool
    @Binding var draft: String
    let activate: () -> Void
    let cancel: () -> Void
    let submit: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Rectangle()
                    .fill(Color(nsColor: .separatorColor).opacity(0.45))
                    .frame(height: 1)
                Button(action: activate) {
                    Image(systemName: "plus.circle.fill")
                        .cmuxSymbolRasterSize(14)
                        .frame(width: 22, height: 18)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(String(localized: "workspaceTasks.insert.help", defaultValue: "Insert task here"))
                .accessibilityLabel(String(localized: "workspaceTasks.insert.label", defaultValue: "Insert Task Here"))
                Rectangle()
                    .fill(Color(nsColor: .separatorColor).opacity(0.45))
                    .frame(height: 1)
            }
            .frame(height: 18)

            if isActive {
                HStack(spacing: 8) {
                    TextField(
                        String(localized: "workspaceTasks.insert.placeholder", defaultValue: "Insert a task"),
                        text: $draft
                    )
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(submit)
                    Button(action: submit) {
                        Image(systemName: "checkmark")
                            .cmuxSymbolRasterSize(13)
                            .frame(width: 24, height: 22)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(WorkspaceTask.normalizedTitle(draft).isEmpty)
                    .help(String(localized: "workspaceTasks.insert.submit", defaultValue: "Insert task"))
                    .accessibilityLabel(String(localized: "workspaceTasks.insert.submit", defaultValue: "Insert task"))
                    Button(action: cancel) {
                        Image(systemName: "xmark")
                            .cmuxSymbolRasterSize(12)
                            .frame(width: 24, height: 22)
                    }
                    .buttonStyle(.plain)
                    .help(String(localized: "workspaceTasks.insert.cancel", defaultValue: "Cancel insert"))
                    .accessibilityLabel(String(localized: "workspaceTasks.insert.cancel", defaultValue: "Cancel insert"))
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

private struct WorkspaceTaskIconButton: View {
    let systemName: String
    let label: String
    var role: ButtonRole? = nil
    var isDisabled: Bool = false
    let action: () -> Void

    var body: some View {
        Button(role: role, action: action) {
            Image(systemName: systemName)
                .cmuxSymbolRasterSize(12)
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .help(label)
        .accessibilityLabel(label)
    }
}
