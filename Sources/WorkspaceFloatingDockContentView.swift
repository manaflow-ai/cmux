import CmuxAppKitSupportUI
import SwiftUI

/// SwiftUI root mounted inside a workspace floating Dock window.
struct WorkspaceFloatingDockContentView: View {
    let dock: WorkspaceFloatingDock

    var body: some View {
        DockPanelView(
            store: dock.store,
            isSidebarVisible: dock.isPresented,
            mode: .dock,
            rootDirectory: nil,
            windowAppearance: AppWindowChromeComposition().appearanceSnapshotFromUserDefaults(),
            rightSidebarOwnsInputFocus: dock.ownsInputFocus,
            onKeyboardFocusIntent: {}
        )
        .frame(minWidth: 320, minHeight: 220)
        .accessibilityIdentifier("WorkspaceFloatingDock")
    }
}
