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
    @Binding var suppressNextTerminalAutoFocus: Bool
    @Binding var terminalAutoFocusSuppressedSurfaceIDs: Set<String>

    private var workspace: MobileWorkspacePreview? {
        if let workspaceID {
            return store.workspaces.first { $0.id == workspaceID } ?? store.selectedWorkspace
        }
        return store.selectedWorkspace
    }

    var body: some View {
        if let workspace {
            WorkspaceDetailView(
                host: store.connectedHostName,
                connectionStatus: store.macConnectionStatus,
                workspace: workspace,
                store: store,
                selectedTerminalID: Binding(
                    get: { store.selectedTerminalID },
                    set: { store.selectTerminal($0) }
                ),
                createWorkspace: createWorkspace,
                createTerminal: { store.createTerminal(in: workspace.id) },
                reportTerminalViewport: store.reportTerminalViewport,
                sendTerminalInput: store.sendTerminalRawInput,
                safeAreaContext: safeAreaContext,
                suppressNextTerminalAutoFocus: $suppressNextTerminalAutoFocus,
                terminalAutoFocusSuppressedSurfaceIDs: $terminalAutoFocusSuppressedSurfaceIDs
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
