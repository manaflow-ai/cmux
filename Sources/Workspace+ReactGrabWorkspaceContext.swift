import CmuxBrowser
import Foundation

/// Adapts a `Workspace` to the `ReactGrabController` (CmuxBrowser) workspace
/// seam. `Workspace` owns the per-window panel layout, focus, and split-zoom
/// state and the app-target panel model, so it cannot move into the package;
/// this conformance exposes exactly what the controller needs and keeps the
/// panel-type-keyed route computation app-side.
extension Workspace: ReactGrabWorkspaceContext {
    var reactGrabWorkspaceId: UUID { id }

    var reactGrabFocusedPanelId: UUID? { focusedPanelId }

    func reactGrabRouteFromFocus() -> ReactGrabRoute? {
        let snapshots = panels.values.map { panel in
            ReactGrabShortcutPanelSnapshot(
                id: panel.id,
                panelType: panel.panelType,
                isFocused: panel.id == focusedPanelId
            )
        }
        guard let route = resolveReactGrabShortcutRoute(panels: snapshots) else { return nil }
        return ReactGrabRoute(
            browserPanelId: route.browserPanelId,
            returnTerminalPanelId: route.returnTerminalPanelId
        )
    }

    func reactGrabBrowserActing(for panelId: UUID) -> (any ReactGrabBrowserActing)? {
        browserPanel(for: panelId)
    }

    func reactGrabPanelIsTerminal(_ panelId: UUID) -> Bool {
        panels[panelId]?.panelType == .terminal
    }

    func reactGrabClearSplitZoom() {
        clearSplitZoom()
    }

    func reactGrabFocusPanel(_ panelId: UUID) {
        focusPanel(panelId)
    }
}
