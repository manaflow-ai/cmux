import CmuxMobileShell
import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

extension WorkspaceDetailView {
    @ViewBuilder
    var diffReviewMenuButton: some View {
        if store.supportsDiffReview(for: workspace.id) {
            Button(action: openDiffReviewFromMenu) {
                Label(
                    L10n.string("mobile.diff.reviewChanges", defaultValue: "Review Changes"),
                    systemImage: "doc.text.magnifyingglass"
                )
            }
            .accessibilityIdentifier("MobileReviewChangesMenuItem")
        }
    }

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
                fetchFile: { path in
                    try await store.fetchFileDiff(workspaceID: workspace.id, path: path)
                }
            )
        }
    }
}
