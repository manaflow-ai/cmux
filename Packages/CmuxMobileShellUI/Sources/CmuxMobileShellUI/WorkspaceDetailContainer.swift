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
        guard let workspaceID else { return store.selectedWorkspace }
        // The detail is always pushed for the selected workspace, so when the
        // routed id is the current selection, resolve through the store's
        // mac-scoped `selectedWorkspace`. A bare `store.workspaces.first { id }`
        // would pick the first partition under a cross-Mac id collision and open
        // the wrong Mac's detail; preferring the scoped selection avoids that.
        if store.selectedWorkspaceID == workspaceID, let selected = store.selectedWorkspace {
            return selected
        }
        return store.workspaces.first { $0.id == workspaceID } ?? store.selectedWorkspace
    }

    var body: some View {
        if let workspace {
            WorkspaceDetailView(
                host: store.connectedHostName,
                connectionStatus: store.macConnectionStatus,
                workspace: workspace,
                store: store,
                createWorkspace: createWorkspace,
                createTerminal: { store.createTerminal(in: workspace.id) },
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
