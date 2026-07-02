import CmuxMobileDiagnostics
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
    let safeAreaContext: MobileTerminalSafeAreaContext
    let backButtonConfiguration: WorkspaceBackButtonConfiguration?
    let signOut: (() -> Void)?

    private var workspace: MobileWorkspacePreview? {
        if let workspaceID {
            return store.workspaces.first { $0.id == workspaceID } ?? store.selectedWorkspace
        }
        return store.selectedWorkspace
    }

    /// Close-workspace closure for the detail top-bar menu. Present only when
    /// this workspace's owning Mac advertises `workspace.close.v1`, matching the
    /// workspace list's row-scoped gating. Built as an explicit closure literal
    /// because the compiler fails to type-check a method-reference ternary
    /// inside the large `WorkspaceDetailView` init.
    private var closeWorkspaceClosure: ((MobileWorkspacePreview.ID) -> Void)? {
        guard workspace?.actionCapabilities.supportsCloseActions == true else { return nil }
        let store = store
        return { id in Task { await store.closeWorkspace(id: id) } }
    }

    private var closeTerminalClosure: ((MobileTerminalPreview.ID) -> Void)? {
        guard let workspace,
              workspace.actionCapabilities.supportsTerminalCloseActions else { return nil }
        let workspaceID = workspace.id
        let store = store
        return { terminalID in
            Task { await store.closeTerminal(workspaceID: workspaceID, terminalID: terminalID) }
        }
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
                    closeWorkspace: closeWorkspaceClosure,
                    closeTerminal: closeTerminalClosure,
                    reportTerminalViewport: store.reportTerminalViewport,
                    sendTerminalInput: store.sendTerminalRawInput,
                    safeAreaContext: safeAreaContext,
                    backButtonConfiguration: backButtonConfiguration,
                    signOut: signOut
                )
                .onAppear {
                    #if DEBUG
                    MobileDebugLog.anchormux(
                        "toolbar.container.detailAppear requested=\(workspaceID?.rawValue ?? "nil") resolved=\(workspace.id.rawValue) selected=\(store.selectedWorkspaceID?.rawValue ?? "nil") terminals=\(workspace.terminals.count) back=\(backButtonConfiguration != nil)"
                    )
                    #endif
                    if store.selectedWorkspaceID != workspace.id {
                        store.selectedWorkspaceID = workspace.id
                    }
                }
                #if DEBUG
                .onDisappear {
                    MobileDebugLog.anchormux(
                        "toolbar.container.detailDisappear requested=\(workspaceID?.rawValue ?? "nil") resolved=\(workspace.id.rawValue) selected=\(store.selectedWorkspaceID?.rawValue ?? "nil")"
                    )
                }
                #endif
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
        #if DEBUG
        .onAppear {
            MobileDebugLog.anchormux("toolbar.container.appear \(debugSignature)")
        }
        .onChange(of: debugSignature) { _, signature in
            MobileDebugLog.anchormux("toolbar.container.change \(signature)")
        }
        #endif
    }

    #if DEBUG
    private var debugSignature: String {
        [
            "requested=\(workspaceID?.rawValue ?? "nil")",
            "resolved=\(workspace?.id.rawValue ?? "nil")",
            "selected=\(store.selectedWorkspaceID?.rawValue ?? "nil")",
            "selectedTerminal=\(store.selectedTerminalID?.rawValue ?? "nil")",
            "workspaces=\(store.workspaces.map(\.id.rawValue).joined(separator: ","))",
            "back=\(backButtonConfiguration != nil)",
        ].joined(separator: " ")
    }
    #endif
}
