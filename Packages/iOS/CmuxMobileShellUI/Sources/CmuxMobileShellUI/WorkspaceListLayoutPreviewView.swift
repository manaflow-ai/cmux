#if canImport(UIKit) && DEBUG
import CmuxMobileBrowser
import CmuxMobileShell
import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

/// DEBUG-only workspace surface-grid fixture for simulator layout screenshots.
///
/// Mounted by the root view when `CMUX_UITEST_WORKSPACE_LIST_PREVIEW=1`.
/// It exercises the production Safari-style surface overview with static
/// terminal/browser rows, avoiding auth and Mac pairing while keeping layout code
/// identical to the compact shell root.
public struct WorkspaceListLayoutPreviewView: View {
    @State private var selectedWorkspaceID: MobileWorkspacePreview.ID? = "workspace-main"
    @State private var selectedTerminalID: MobileTerminalPreview.ID? = "terminal-build"
    @State private var browserStore = BrowserSurfaceStore(defaultURL: URL(string: "https://cmux.dev/"))

    public init() {}

    @State private var workspaces: [MobileWorkspacePreview] = [
        MobileWorkspacePreview(
            id: "workspace-main",
            macDeviceID: "preview-macbook-pro",
            macDisplayName: "MacBook Pro",
            name: "cmux",
            terminals: [
                MobileTerminalPreview(id: "terminal-build", name: "Build"),
                MobileTerminalPreview(id: "terminal-agent", name: "Agent"),
            ]
        ),
        MobileWorkspacePreview(
            id: "workspace-ios",
            macDeviceID: "preview-macbook-pro",
            macDisplayName: "MacBook Pro",
            name: "iOS avatar tuning",
            hasUnread: true,
            terminals: [
                MobileTerminalPreview(id: "terminal-ios", name: "Agent"),
            ]
        ),
        MobileWorkspacePreview(
            id: "workspace-docs",
            macDeviceID: "preview-studio",
            macDisplayName: "Studio Display Bench With A Very Long Name",
            name: "Docs",
            terminals: [
                MobileTerminalPreview(id: "terminal-notes", name: "Notes"),
            ]
        ),
    ]

    public var body: some View {
        Group {
            if UITestConfig.workspaceDetailCreateDelayedTerminalPreviewEnabled {
                WorkspaceDetailCreateDelayedTerminalPreviewView()
            } else if UITestConfig.workspaceDetailRefreshingTerminalMenuPreviewEnabled {
                WorkspaceDetailDelayedTerminalPreviewView()
            } else if UITestConfig.workspaceDetailDelayedTerminalPreviewEnabled {
                WorkspaceDetailDelayedTerminalPreviewView()
            } else {
                NavigationStack {
                    WorkspaceSurfaceGridView(
                        workspaces: workspaces,
                        selectedWorkspaceID: selectedWorkspaceID,
                        selectedTerminalID: selectedTerminalID,
                        host: L10n.string("mobile.preview.mockMacName", defaultValue: "Visual Mock Mac"),
                        connectionStatus: .connected,
                        canCreateWorkspace: true,
                        canCreateTerminal: true,
                        selectWorkspace: selectWorkspace,
                        openTerminal: { workspaceID, terminalID in
                            selectedWorkspaceID = workspaceID
                            selectedTerminalID = terminalID
                            if let workspace = workspaces.first(where: { $0.id == workspaceID }) {
                                browserStore.showNonBrowserSurface(for: workspace.browserSurfaceIdentity)
                            }
                        },
                        openBrowser: { workspaceID in
                            selectedWorkspaceID = workspaceID
                            if let workspace = workspaces.first(where: { $0.id == workspaceID }) {
                                browserStore.openBrowser(for: workspace.browserSurfaceIdentity)
                            }
                        },
                        closeBrowser: { workspaceID in
                            if let workspace = workspaces.first(where: { $0.id == workspaceID }) {
                                browserStore.closeBrowser(for: workspace.browserSurfaceIdentity)
                            }
                        },
                        createWorkspace: createWorkspace,
                        createTerminal: createTerminal,
                        refresh: {},
                        showSettings: {},
                        showDevices: {},
                        showWorkspaceManager: nil,
                        reconnect: nil,
                        isInitialConnectionLoading: false,
                        initialConnectionTimedOut: false,
                        retryInitialConnection: nil,
                        showAddDevice: nil
                    )
                }
            }
        }
        .environment(browserStore)
        .onAppear {
            if let workspace = workspaces.first(where: { $0.id == "workspace-main" }) {
                browserStore.openBrowser(for: workspace.browserSurfaceIdentity)
            }
        }
    }

    private func createWorkspace() {
        let index = workspaces.count + 1
        let workspace = MobileWorkspacePreview(
            id: MobileWorkspacePreview.ID(rawValue: "workspace-preview-\(index)"),
            name: L10n.workspaceName(index: index),
            terminals: [
                MobileTerminalPreview(
                    id: MobileTerminalPreview.ID(rawValue: "terminal-preview-\(index)"),
                    name: L10n.terminalName(index: index)
                ),
            ]
        )
        workspaces.append(workspace)
        selectedWorkspaceID = workspace.id
        selectedTerminalID = workspace.terminals.first?.id
    }

    private func selectWorkspace(_ workspaceID: MobileWorkspacePreview.ID) {
        selectedWorkspaceID = workspaceID
        selectedTerminalID = workspaces.first(where: { $0.id == workspaceID })?.terminals.first?.id
    }

    private func createTerminal(_ workspaceID: MobileWorkspacePreview.ID) {
        guard let index = workspaces.firstIndex(where: { $0.id == workspaceID }) else { return }
        let next = workspaces[index].terminals.count + 1
        let terminal = MobileTerminalPreview(
            id: MobileTerminalPreview.ID(rawValue: "\(workspaceID.rawValue)-terminal-\(next)"),
            name: L10n.terminalName(index: next)
        )
        workspaces[index].terminals.append(terminal)
        selectedWorkspaceID = workspaceID
        selectedTerminalID = terminal.id
        browserStore.showNonBrowserSurface(for: workspaces[index].browserSurfaceIdentity)
    }
}
#endif
