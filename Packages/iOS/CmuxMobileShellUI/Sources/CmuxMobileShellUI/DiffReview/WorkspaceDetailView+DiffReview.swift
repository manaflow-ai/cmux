import CmuxMobileShell
import CmuxMobileShellModel
import SwiftUI

extension WorkspaceDetailView {
    func openDiffReviewFromMenu() {
        isDiffReviewPresented = true
    }
}

extension View {
    func diffReviewEntry(
        isPresented: Binding<Bool>,
        store: CMUXMobileShellStore,
        workspace: MobileWorkspacePreview
    ) -> some View {
        navigationDestination(isPresented: isPresented) {
            DiffReviewFilesView(
                workspaceName: workspace.name,
                fetchStatus: {
                    try await store.fetchDiffStatus(workspaceID: workspace.id)
                },
                fetchFile: { path, oldPath, status, repoRoot in
                    try await store.fetchFileDiff(
                        workspaceID: workspace.id,
                        path: path,
                        oldPath: oldPath,
                        status: status,
                        repoRoot: repoRoot
                    )
                }
            )
        }
    }
}
