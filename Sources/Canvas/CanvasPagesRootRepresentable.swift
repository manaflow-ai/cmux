import AppKit
import SwiftUI
import CmuxCanvasUI

/// Bridges descriptor snapshots into the package's native Pages host.
struct CanvasPagesRootRepresentable: NSViewRepresentable {
    let workspace: Workspace
    let descriptors: [CanvasPaneDescriptor]
    let focusedPanelId: UUID?
    let isWorkspaceVisible: Bool

    func makeNSView(context: Context) -> CanvasPagesRootView {
        let workspace = workspace
        return CanvasPagesRootView(
            model: workspace.canvasModel,
            callbacks: CanvasHostCallbacks(
                onFocusPanel: { [weak workspace] panelId in
                    guard let workspace else { return }
                    AppDelegate.shared?.noteMainPanelKeyboardFocusIntent(
                        workspaceId: workspace.id,
                        panelId: panelId,
                        in: NSApp.keyWindow ?? NSApp.mainWindow
                    )
                    workspace.focusPanel(panelId)
                },
                onClosePanel: { [weak workspace] panelId in
                    _ = workspace?.closePanel(panelId)
                },
                onLayoutChanged: { [weak workspace] in
                    guard let workspace else { return }
                    workspace.noteCanvasLayoutChanged()
                    _ = workspace.reconcileBrowserPortalVisibilityForCurrentRenderedLayout(
                        reason: "pages.layoutChanged"
                    )
                },
                onViewportGeometryChanged: { [weak workspace] window in
                    _ = workspace?.reconcileTerminalPortalVisibilityForCurrentRenderedLayout()
                    _ = workspace?.reconcileBrowserPortalVisibilityForCurrentRenderedLayout(
                        reason: "pages.viewportGeometryChanged"
                    )
                    guard let window else { return }
                    BrowserWindowPortalRegistry.scheduleExternalGeometrySynchronize(for: window)
                },
                onViewportSettled: { [weak workspace] window in
                    _ = workspace?.reconcileTerminalPortalVisibilityForCurrentRenderedLayout()
                    _ = workspace?.reconcileBrowserPortalVisibilityForCurrentRenderedLayout(
                        reason: "pages.viewportSettled"
                    )
                    guard let window else { return }
                    BrowserWindowPortalRegistry.scheduleExternalGeometrySynchronize(for: window)
                }
            ),
            themeProvider: {
                let background = GhosttyBackgroundTheme.currentColor()
                return CanvasTheme(canvasBackground: background, paneBackground: background)
            }
        )
    }

    func updateNSView(_ nsView: CanvasPagesRootView, context: Context) {
        nsView.sync(
            descriptors: descriptors,
            focusedPanelId: focusedPanelId,
            isWorkspaceVisible: isWorkspaceVisible
        )
    }

    static func dismantleNSView(_ nsView: CanvasPagesRootView, coordinator: ()) {
        nsView.teardown()
    }
}
