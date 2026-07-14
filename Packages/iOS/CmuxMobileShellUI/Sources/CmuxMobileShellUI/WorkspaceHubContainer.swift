import CmuxMobileShell
import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

/// Resolves live store state before crossing into the snapshot-only hub view.
struct WorkspaceHubContainer: View {
    @Bindable var store: CMUXMobileShellStore
    let workspaceID: MobileWorkspacePreview.ID?
    let backButtonConfiguration: WorkspaceBackButtonConfiguration?
    let selectPane: (WorkspaceHubPaneSnapshot) -> Void
    let signOut: (() -> Void)?
    @State private var routeWorkspaceSnapshot: MobileWorkspacePreview?

    private var workspace: MobileWorkspacePreview? {
        if let workspaceID {
            return store.workspaces.first(where: { $0.id == workspaceID })
                ?? (routeWorkspaceSnapshot?.id == workspaceID ? routeWorkspaceSnapshot : nil)
        }
        return store.selectedWorkspace
    }

    var body: some View {
        Group {
            if let workspace {
                WorkspaceHubView(
                    workspace: workspace,
                    layout: store.workspaceLayout(for: workspace.id),
                    connectionStatus: workspace.macConnectionStatus ?? store.macConnectionStatus,
                    previewUpdates: store.previewGridUpdates,
                    selectPane: selectPane,
                    backButtonConfiguration: backButtonConfiguration
                )
                .onAppear {
                    rememberRouteWorkspace(workspace)
                    if store.selectedWorkspaceID != workspace.id {
                        store.selectedWorkspaceID = workspace.id
                    }
                }
                .onChange(of: workspace) { _, updatedWorkspace in
                    rememberRouteWorkspace(updatedWorkspace)
                }
                .task(id: workspace.id) {
                    await store.openWorkspace(workspace.id)
                }
            } else {
                ContentUnavailableView(
                    L10n.string("mobile.workspace.emptyTitle", defaultValue: "No Workspace"),
                    systemImage: "rectangle.stack"
                )
            }
        }
        .mobileConnectionRecoveryOverlay(store: store, signOut: signOut)
    }

    private func rememberRouteWorkspace(_ workspace: MobileWorkspacePreview) {
        guard workspaceID == workspace.id else { return }
        routeWorkspaceSnapshot = workspace
    }
}
