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
            onKeyboardFocusIntent: {},
            usesTransparentBackground: true,
            tabBarLeadingInset: WorkspaceFloatingDockChromeMetrics.tabBarLeadingInset
        )
        .frame(minWidth: 320, minHeight: 220)
        .ignoresSafeArea(.container, edges: .top)
        .overlay(alignment: .topLeading) {
            WorkspaceFloatingDockTitlebarIdentity()
                .padding(.leading, WorkspaceFloatingDockChromeMetrics.trafficLightClearance)
        }
        // The native transparent titlebar and every Bonsplit surface share the
        // same Liquid Glass substrate in the mouse-ignoring backdrop window.
        .background(Color.primary.opacity(0.035))
        .accessibilityIdentifier("WorkspaceFloatingDock")
    }
}

enum WorkspaceFloatingDockChromeMetrics {
    static let trafficLightClearance: CGFloat = 78
    static let tabBarLeadingInset: CGFloat = 112
    static let identityWidth = tabBarLeadingInset - trafficLightClearance
}

private struct WorkspaceFloatingDockTitlebarIdentity: View {
    var body: some View {
        ZStack {
            WorkspaceFloatingDockTitlebarDragRegion()
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .allowsHitTesting(false)
        }
        .frame(
            width: WorkspaceFloatingDockChromeMetrics.identityWidth,
            height: WindowChromeMetrics.bonsplitTabBarHeight
        )
        .accessibilityIdentifier("WorkspaceFloatingDockTitlebarIdentity")
    }
}

private struct WorkspaceFloatingDockTitlebarDragRegion: NSViewRepresentable {
    func makeNSView(context: Context) -> WorkspaceFloatingDockTitlebarDragNSView {
        WorkspaceFloatingDockTitlebarDragNSView()
    }

    func updateNSView(_ nsView: WorkspaceFloatingDockTitlebarDragNSView, context: Context) {}
}

final class WorkspaceFloatingDockTitlebarDragNSView: NSView {
    override var mouseDownCanMoveWindow: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        window.makeKey()
        if event.clickCount >= 2 {
            let action = UserDefaults.standard
                .persistentDomain(forName: UserDefaults.globalDomain)?["AppleActionOnDoubleClick"] as? String
            if action == "Minimize" {
                window.miniaturize(nil)
            } else {
                window.zoom(nil)
            }
        } else {
            window.performDrag(with: event)
        }
    }
}
