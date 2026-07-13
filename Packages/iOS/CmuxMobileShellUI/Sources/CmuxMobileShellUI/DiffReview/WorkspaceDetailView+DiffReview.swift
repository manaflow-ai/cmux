import CmuxMobileShell
import CmuxMobileShellModel
import SwiftUI

struct DiffReviewWorkspaceIdentity: Hashable {
    /// Workspace selection owns the complete review session and navigation state.
    let workspaceID: MobileWorkspacePreview.ID
}

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
                fetchFile: { file, repoRoot in
                    try await store.fetchFileDiff(
                        workspaceID: workspace.id,
                        file: file,
                        repoRoot: repoRoot
                    )
                }
            )
            .id(DiffReviewWorkspaceIdentity(workspaceID: workspace.id))
        }
    }
}
