import CmuxAppKitSupportUI
import SwiftUI

/// SwiftUI root mounted inside a workspace floating Dock window.
struct WorkspaceFloatingDockContentView: View {
    let dock: WorkspaceFloatingDock

    var body: some View {
        DockPanelView(
            store: dock.store,
            isSidebarVisible: true,
            mode: .dock,
            rootDirectory: nil,
            windowAppearance: AppWindowChromeComposition().appearanceSnapshotFromUserDefaults(),
            rightSidebarOwnsInputFocus: dock.ownsInputFocus,
            onKeyboardFocusIntent: {},
            usesTransparentBackground: true,
            tabBarLeadingInset: WorkspaceFloatingDockChromeMetrics.tabBarLeadingInset
        )
        .frame(minWidth: 320, minHeight: 220)
        .ignoresSafeArea(.container, edges: .top)
        // The native transparent titlebar and every Bonsplit surface share the
        // same Liquid Glass substrate in the mouse-ignoring backdrop window.
        .background(Color.clear)
        .accessibilityIdentifier("WorkspaceFloatingDock")
    }
}

enum WorkspaceFloatingDockChromeMetrics {
    static let trafficLightClearance: CGFloat = 78
    static let tabBarLeadingInset = trafficLightClearance
}
