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
    let safeAreaContext: MobileTerminalSafeAreaContext

    private var workspace: MobileWorkspacePreview? {
        if let workspaceID {
            return store.workspaces.first { $0.id == workspaceID } ?? store.selectedWorkspace
        }
        return store.selectedWorkspace
    }

    /// Close-workspace closure for the detail top-bar menu. Uses the same
    /// serialized delete path as the workspace list so selection moves to a
    /// neighbor before the remote close reconciles.
    private var closeWorkspaceClosure: ((MobileWorkspacePreview.ID) -> Void)? {
        guard store.supportsWorkspaceCloseActions || store.supportsDeleteActions else { return nil }
        let store = store
        return { id in store.deleteWorkspace(id: id) }
    }

    var body: some View {
        if let workspace {
            WorkspaceDetailView(
                host: store.connectedHostName,
                connectionStatus: store.macConnectionStatus,
                workspace: workspace,
                store: store,
                createWorkspace: createWorkspace,
                createTerminal: {
                    store.createTerminal(in: workspace.id)
                },
                deleteTerminal: { workspaceID, terminalID in
                    store.deleteTerminal(id: terminalID, in: workspaceID)
                },
                closeWorkspace: closeWorkspaceClosure,
                reportTerminalViewport: store.reportTerminalViewport,
                sendTerminalInput: store.sendTerminalRawInput,
                safeAreaContext: safeAreaContext
            )
            .onAppear {
                if store.selectedWorkspaceID != workspace.id {
                    store.selectedWorkspaceID = workspace.id
                }
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
