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

    /// The display name of the workspace's source Mac, or the active host name for
    /// an untagged (synthetic/preview) workspace.
    private func hostName(for workspace: MobileWorkspacePreview) -> String {
        guard !workspace.sourceMacDeviceID.isEmpty else { return store.connectedHostName }
        return store.macDisplayName(forMacDeviceID: workspace.sourceMacDeviceID)
    }

    /// The connectivity status of the workspace's source Mac, or the active Mac's
    /// status for an untagged (synthetic/preview) workspace.
    private func connectionStatus(for workspace: MobileWorkspacePreview) -> MobileMacConnectionStatus {
        guard !workspace.sourceMacDeviceID.isEmpty else { return store.macConnectionStatus }
        return store.macStatus(forMacDeviceID: workspace.sourceMacDeviceID)
    }

    var body: some View {
        if let workspace {
            WorkspaceDetailView(
                // Resolve host + status from the workspace's OWN source Mac, not
                // the active heavy-session Mac: a detail opened for a non-active
                // (or mid-retarget) Mac must not show the active Mac's connected
                // chrome while its input/replay are dropped by the active-Mac
                // guards. Falls back to active-Mac metadata only for an untagged
                // workspace (synthetic/preview with no source Mac).
                host: hostName(for: workspace),
                connectionStatus: connectionStatus(for: workspace),
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
