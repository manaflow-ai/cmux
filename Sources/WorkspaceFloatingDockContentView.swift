import CmuxAppKitSupportUI
import SwiftUI

/// SwiftUI root mounted inside a workspace floating Dock window.
struct WorkspaceFloatingDockContentView: View {
    let dock: WorkspaceFloatingDock
    let onCreateDock: () -> Void

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
        .overlay(alignment: .top) {
            HStack(spacing: 0) {
                Color.clear
                    .frame(width: WorkspaceFloatingDockChromeMetrics.trafficLightClearance)
                    .allowsHitTesting(false)

                // Reuse cmux's explicit titlebar drag routing so every empty
                // part of the Dock chrome moves the panel while pane tabs and
                // registered controls keep their own mouse gestures.
                WindowDragHandleView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity)
            .frame(height: WindowChromeMetrics.bonsplitTabBarHeight)
        }
        .overlay(alignment: .topLeading) {
            WorkspaceFloatingDockTitlebarIdentity(onCreateDock: onCreateDock)
                .padding(.leading, WorkspaceFloatingDockChromeMetrics.trafficLightClearance)
        }
        // The native transparent titlebar and every Bonsplit surface share the
        // same Liquid Glass substrate in the mouse-ignoring backdrop window.
        .background(Color.clear)
        .accessibilityIdentifier("WorkspaceFloatingDock")
    }
}

enum WorkspaceFloatingDockChromeMetrics {
    static let trafficLightClearance: CGFloat = 78
    static let dragRegionWidth: CGFloat = 34
    static let newDockButtonWidth: CGFloat = 28
    static let tabBarLeadingInset = trafficLightClearance + dragRegionWidth + newDockButtonWidth
    static let identityWidth = tabBarLeadingInset - trafficLightClearance
}

private struct WorkspaceFloatingDockTitlebarIdentity: View {
    let onCreateDock: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            WorkspaceFloatingDockTitlebarDragRegion()
                .frame(
                    width: WorkspaceFloatingDockChromeMetrics.dragRegionWidth,
                    height: WindowChromeMetrics.bonsplitTabBarHeight
                )
                .overlay {
                    Image(systemName: "square.grid.2x2")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .allowsHitTesting(false)
                }

            Button(action: onCreateDock) {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .frame(width: WorkspaceFloatingDockChromeMetrics.newDockButtonWidth)
            .titlebarInteractiveControl()
            .help("floatingDock.window.new")
            .accessibilityLabel(Text("floatingDock.window.new"))
            .accessibilityIdentifier("WorkspaceFloatingDockNewDockButton")
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
            withTemporaryWindowMovableEnabled(window: window) {
                window.performDrag(with: event)
            }
        }
    }
}
