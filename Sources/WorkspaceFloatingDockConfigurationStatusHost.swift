import SwiftUI

/// Reuses the right Dock's trust and error presentation for project float config loading.
struct WorkspaceFloatingDockConfigurationStatusHost: View {
    let workspace: Workspace
    let windowDockStore: DockSplitStore
    let isSidebarVisible: Bool
    let mode: RightSidebarMode
    let rootDirectory: String
    let windowAppearance: WindowAppearanceSnapshot
    let rightSidebarOwnsInputFocus: Bool
    @State private var configurationStore: DockSplitStore?

    var body: some View {
        Group {
            if let configurationStore,
               configurationStore.trustRequest != nil || configurationStore.errorMessage != nil {
                DockPanelView(
                    store: configurationStore,
                    isSidebarVisible: isSidebarVisible,
                    mode: mode,
                    rootDirectory: rootDirectory,
                    windowAppearance: windowAppearance,
                    rightSidebarOwnsInputFocus: rightSidebarOwnsInputFocus
                )
            } else {
                DockPanelView(
                    store: windowDockStore,
                    isSidebarVisible: isSidebarVisible,
                    mode: mode,
                    rootDirectory: nil,
                    windowAppearance: windowAppearance,
                    rightSidebarOwnsInputFocus: rightSidebarOwnsInputFocus
                )
            }
        }
        .onAppear {
            configurationStore = workspace.floatingDockConfigurationStore()
            workspace.ensureFloatingDockConfigurationLoaded()
        }
    }
}
