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

    /// Close-workspace closure for the detail top-bar menu. Present only when the
    /// connected Mac advertises `workspace.close.v1`, matching the workspace
    /// list's gating so the menu item stays hidden on older Macs. Built as an
    /// explicit closure literal (the compiler fails to type-check a
    /// method-reference ternary inside the large `WorkspaceDetailView` init).
    private var closeWorkspaceClosure: ((MobileWorkspacePreview.ID) -> Void)? {
        guard store.supportsWorkspaceCloseActions else { return nil }
        let store = store
        return { id in Task { await store.closeWorkspace(id: id) } }
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
