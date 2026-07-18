import CmuxAppKitSupportUI
import SwiftUI

struct WorkspaceFloatingDockWindowActions {
    let close: () -> Void
    let minimize: () -> Void
    let zoom: () -> Void
}

/// SwiftUI root mounted inside a workspace floating Dock window.
struct WorkspaceFloatingDockContentView: View {
    let dock: WorkspaceFloatingDock
    let windowActions: WorkspaceFloatingDockWindowActions

    var body: some View {
        VStack(spacing: 0) {
            WorkspaceFloatingDockTitlebar(
                title: dock.title,
                windowActions: windowActions
            )
            DockPanelView(
                store: dock.store,
                isSidebarVisible: dock.isPresented,
                mode: .dock,
                rootDirectory: nil,
                windowAppearance: AppWindowChromeComposition().appearanceSnapshotFromUserDefaults(),
                rightSidebarOwnsInputFocus: dock.ownsInputFocus,
                onKeyboardFocusIntent: {},
                usesTransparentBackground: true
            )
        }
        .frame(minWidth: 320, minHeight: 220)
        // One glass substrate lives below the entire window. Keep every hosted
        // surface clear and use a single translucent tint so the titlebar,
        // Bonsplit chrome, and content read as one continuous material.
        .background(Color.primary.opacity(0.035))
        .accessibilityIdentifier("WorkspaceFloatingDock")
    }
}

private struct WorkspaceFloatingDockTitlebar: View {
    let title: String
    let windowActions: WorkspaceFloatingDockWindowActions

    var body: some View {
        ZStack {
            WorkspaceFloatingDockDragRegion()
            HStack(spacing: 10) {
                HStack(spacing: 7) {
                    Image(systemName: "square.grid.2x2")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                        .foregroundStyle(.primary.opacity(0.86))
                }
                .allowsHitTesting(false)

                Spacer(minLength: 12)

                HStack(spacing: 6) {
                    WorkspaceFloatingDockControlButton(
                        systemName: "chevron.down",
                        accessibilityLabel: String(
                            localized: "floatingDock.window.minimize",
                            defaultValue: "Minimize Floating Dock"
                        ),
                        action: windowActions.minimize
                    )
                    WorkspaceFloatingDockControlButton(
                        systemName: "arrow.up.left.and.arrow.down.right",
                        accessibilityLabel: String(
                            localized: "floatingDock.window.zoom",
                            defaultValue: "Zoom Floating Dock"
                        ),
                        action: windowActions.zoom
                    )
                    WorkspaceFloatingDockControlButton(
                        systemName: "xmark",
                        accessibilityLabel: String(
                            localized: "floatingDock.window.close",
                            defaultValue: "Close Floating Dock"
                        ),
                        role: .destructive,
                        action: windowActions.close
                    )
                }
            }
            .padding(.leading, 12)
            .padding(.trailing, 8)
        }
        .frame(height: 38)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.primary.opacity(0.10))
                .frame(height: 0.5)
                .allowsHitTesting(false)
        }
        .accessibilityIdentifier("WorkspaceFloatingDockTitlebar")
    }
}

private struct WorkspaceFloatingDockControlButton: View {
    let systemName: String
    let accessibilityLabel: String
    var role: ButtonRole?
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(role: role, action: action) {
            Image(systemName: systemName)
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 24, height: 24)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(foregroundStyle)
        .modifier(WorkspaceFloatingDockControlBackground(isHovered: isHovered))
        .onHover { isHovered = $0 }
        .accessibilityLabel(accessibilityLabel)
        .help(accessibilityLabel)
    }

    private var foregroundStyle: Color {
        if role == .destructive, isHovered {
            return .red
        }
        return .primary.opacity(isHovered ? 0.90 : 0.62)
    }
}

private struct WorkspaceFloatingDockControlBackground: ViewModifier {
    let isHovered: Bool

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .background(Color.primary.opacity(isHovered ? 0.08 : 0.025), in: Circle())
                .glassEffect(.regular.interactive(true), in: Circle())
        } else {
            content
                .background(.ultraThinMaterial, in: Circle())
                .overlay {
                    Circle()
                        .stroke(Color.primary.opacity(isHovered ? 0.18 : 0.09), lineWidth: 0.5)
                }
        }
    }
}

private struct WorkspaceFloatingDockDragRegion: NSViewRepresentable {
    func makeNSView(context: Context) -> WorkspaceFloatingDockDragNSView {
        WorkspaceFloatingDockDragNSView()
    }

    func updateNSView(_ nsView: WorkspaceFloatingDockDragNSView, context: Context) {}
}

private final class WorkspaceFloatingDockDragNSView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        window.makeKey()
        if event.clickCount == 2 {
            window.zoom(nil)
        } else {
            window.performDrag(with: event)
        }
    }
}
