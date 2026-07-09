import SwiftUI

/// Connects the per-window recent-file model to the current sidebar workspace.
struct RecentAgentFilesContainerView: View {
    @Environment(\.agentRecentFilesModel) private var model

    let workspaceID: UUID?
    let rootDirectory: String?
    let isActive: Bool
    let onOpenFilePreview: (String) -> Void

    private var scope: AgentRecentFileScope {
        AgentRecentFileScope(workspaceID: workspaceID, rootDirectory: rootDirectory)
    }

    var body: some View {
        Group {
            if let model {
                RecentAgentFilesSnapshotView(
                    files: model.files,
                    isLoading: model.isLoading,
                    onOpenFilePreview: onOpenFilePreview
                )
            }
        }
        .task(id: isActive ? scope : nil) {
            if isActive {
                model?.activate(scope: scope)
            } else {
                model?.deactivate(scope: scope)
            }
        }
        .onDisappear {
            model?.deactivate(scope: scope)
        }
    }
}
