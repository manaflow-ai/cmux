import CmuxSettingsUI
import SwiftUI

struct WorkspaceTasksPopoverView: View {
    let workspace: Workspace
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
