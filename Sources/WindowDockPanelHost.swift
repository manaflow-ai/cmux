import CmuxAppKitSupportUI
import SwiftUI

/// Preserves the per-window Dock store while observing only its selected
/// workspace's configuration and remote-browser snapshot.
struct WindowDockPanelHost: View {
    let store: DockSplitStore
    let workspace: Workspace
    let isSidebarVisible: Bool
    let mode: RightSidebarMode
    let windowAppearance: WindowAppearanceSnapshot
    let rightSidebarOwnsInputFocus: Bool
    @State private var observation: WindowDockWorkspaceObservation

    init(
        store: DockSplitStore,
        workspace: Workspace,
        isSidebarVisible: Bool,
        mode: RightSidebarMode,
        windowAppearance: WindowAppearanceSnapshot,
        rightSidebarOwnsInputFocus: Bool
    ) {
        self.store = store
        self.workspace = workspace
        self.isSidebarVisible = isSidebarVisible
        self.mode = mode
        self.windowAppearance = windowAppearance
        self.rightSidebarOwnsInputFocus = rightSidebarOwnsInputFocus
        _observation = State(initialValue: WindowDockWorkspaceObservation(workspace: workspace))
    }

    var body: some View {
        let snapshot = observation.snapshot

        DockPanelView(
            store: store,
            isSidebarVisible: isSidebarVisible,
            mode: mode,
            rootDirectory: nil,
            windowAppearance: windowAppearance,
            rightSidebarOwnsInputFocus: rightSidebarOwnsInputFocus
        )
        .onAppear {
            observation.observe(workspace)
            store.configurationContextDidChange()
            store.applyRemoteProxyEndpointUpdate(snapshot.proxyEndpoint)
            store.applyRemoteWorkspaceStatus(snapshot.remoteStatus)
        }
        .onChange(of: workspace.id) { _, _ in
            observation.observe(workspace)
        }
        .onChange(of: snapshot.configurationIdentity) { _, _ in
            store.configurationContextDidChange()
        }
        .onChange(of: snapshot.proxyEndpoint) { _, endpoint in
            store.applyRemoteProxyEndpointUpdate(endpoint)
        }
        .onChange(of: snapshot.remoteStatus) { _, status in
            store.applyRemoteWorkspaceStatus(status)
        }
    }
}
