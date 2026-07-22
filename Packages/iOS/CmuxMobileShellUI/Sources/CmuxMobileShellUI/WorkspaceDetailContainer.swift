import CmuxMobileShell
import CmuxMobileShellModel
import CmuxMobileSupport
import CmuxMobileWorkspace
import SwiftUI
#if os(iOS)
@preconcurrency import UIKit
#elseif os(macOS)
import AppKit
#endif

struct WorkspaceDetailContainer: View {
    @Bindable var store: CMUXMobileShellStore
    let workspaceID: MobileWorkspacePreview.ID?
    let createWorkspace: () -> Void
    let canCreateWorkspace: Bool
    let renameWorkspace: ((MobileWorkspacePreview.ID, String) -> Void)?
    let setWorkspaceUnread: ((MobileWorkspacePreview.ID, Bool) -> Void)?
    let closeWorkspace: ((MobileWorkspacePreview.ID) -> Void)?
    let safeAreaContext: MobileTerminalSafeAreaContext
    let backButtonConfiguration: WorkspaceBackButtonConfiguration?
    let signOut: (() -> Void)?
    @State private var routeWorkspaceSnapshot: MobileWorkspacePreview?

    private var workspace: MobileWorkspacePreview? {
        if let workspaceID {
            if let liveWorkspace = store.workspaces.first(where: { $0.id == workspaceID }) {
                return liveWorkspace
            }
            if routeWorkspaceSnapshot?.id == workspaceID {
                return routeWorkspaceSnapshot
            }
            return nil
        }
        return store.selectedWorkspace
    }

    var body: some View {
        Group {
            if let workspace {
                WorkspaceDetailView(
                    host: store.connectedHostName,
                    connectionStatus: workspace.macConnectionStatus ?? store.macConnectionStatus,
                    workspace: workspace,
                    store: store,
                    createWorkspace: createWorkspace,
                    canCreateWorkspace: canCreateWorkspace,
                    createTerminal: { store.createTerminal(in: workspace.id) },
                    renameWorkspace: workspace.actionCapabilities.supportsWorkspaceActions ? renameWorkspace : nil,
                    setWorkspaceUnread: workspace.actionCapabilities.supportsReadStateActions ? setWorkspaceUnread : nil,
                    closeWorkspace: workspace.actionCapabilities.supportsCloseActions ? closeWorkspace : nil,
                    reportTerminalViewport: store.reportTerminalViewport,
                    sendTerminalInput: store.sendTerminalRawInput,
                    safeAreaContext: safeAreaContext,
                    backButtonConfiguration: backButtonConfiguration,
                    signOut: signOut
                )
                .onAppear {
                    rememberRouteWorkspace(workspace)
                    if store.selectedWorkspaceID != workspace.id {
                        store.selectedWorkspaceID = workspace.id
                    }
                }
                .onChange(of: workspace) { _, workspace in
                    rememberRouteWorkspace(workspace)
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
    }

    private func rememberRouteWorkspace(_ workspace: MobileWorkspacePreview) {
        guard workspaceID == workspace.id else { return }
        routeWorkspaceSnapshot = workspace
    }
}
