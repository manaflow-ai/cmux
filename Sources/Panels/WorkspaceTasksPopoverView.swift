import CmuxSettingsUI
import SwiftUI

struct WorkspaceTasksPopoverView: View {
    let workspace: Workspace
    let openSurface: () -> Void

    @State private var addDraft = ""
    @State private var insertionAfterTaskId: UUID?
    @State private var insertionDraft = ""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
                mutate {
                    workspace.addWorkspaceTask(title: title, after: afterTaskId) != nil
                }
            },
            archive: { taskId in
                mutate {
                    _ = workspace.archiveWorkspaceTask(id: taskId)
                }
            },
            unarchive: { taskId in
                mutate {
                    _ = workspace.unarchiveWorkspaceTask(id: taskId)
                }
            },
            remove: { taskId in
                mutate {
                    _ = workspace.removeWorkspaceTask(id: taskId)
                }
            },
            move: { taskId, beforeTaskId, afterTaskId, index in
                mutate {
                    _ = workspace.moveWorkspaceTask(
                        id: taskId,
                        before: beforeTaskId,
                        after: afterTaskId,
                        index: index
                    )
                }
            },
            openSurface: openSurface
        )
    }

    @discardableResult
    private func mutate<T>(_ body: () -> T) -> T {
        if reduceMotion {
            return body()
        }
        return withAnimation(.easeInOut(duration: 0.16), body)
    }
}
