import CmuxSettingsUI
import SwiftUI

struct WorkspaceTasksPanelView: View {
    let panel: WorkspaceTasksPanel
    let workspace: Workspace
    let appearance: PanelAppearance
    let onRequestPanelFocus: () -> Void

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
            openSurface: {}
        )
    }

    @discardableResult
    private func mutate<T>(_ body: () -> T) -> T {
        if reduceMotion {
            return body()
        }
        return withAnimation(.easeInOut(duration: 0.16), body)
    }

    private func requestPanelFocusIfNeeded() {
        guard !panel.isFocusedInWorkspace else { return }
        onRequestPanelFocus()
    }
}
