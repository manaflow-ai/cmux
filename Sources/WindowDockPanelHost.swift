import CmuxAppKitSupportUI
import SwiftUI

/// Observes the selected workspace while preserving the per-window Dock store.
/// Workspace changes refresh config identity and remote browser routing without
/// moving Dock ownership into the workspace lifecycle.
struct WindowDockPanelHost: View {
    let store: DockSplitStore
    @ObservedObject var workspace: Workspace
    let isSidebarVisible: Bool
    let mode: RightSidebarMode
    let windowAppearance: WindowAppearanceSnapshot
    let rightSidebarOwnsInputFocus: Bool

    var body: some View {
        let contextIdentity = workspace.windowDockConfigurationContext().identity
        let proxyEndpoint = workspace.remoteProxyEndpoint
        let remoteStatus = workspace.browserRemoteWorkspaceStatusSnapshot()

        DockPanelView(
            store: store,
            isSidebarVisible: isSidebarVisible,
            mode: mode,
            rootDirectory: nil,
            windowAppearance: windowAppearance,
            rightSidebarOwnsInputFocus: rightSidebarOwnsInputFocus
        )
        .onAppear {
            store.configurationContextDidChange()
            store.applyRemoteProxyEndpointUpdate(proxyEndpoint)
            store.applyRemoteWorkspaceStatus(remoteStatus)
        }
        .onChange(of: contextIdentity) { _, _ in
            store.configurationContextDidChange()
        }
        .onChange(of: proxyEndpoint) { _, endpoint in
            store.applyRemoteProxyEndpointUpdate(endpoint)
        }
        .onChange(of: remoteStatus) { _, status in
            store.applyRemoteWorkspaceStatus(status)
        }
    }
}
