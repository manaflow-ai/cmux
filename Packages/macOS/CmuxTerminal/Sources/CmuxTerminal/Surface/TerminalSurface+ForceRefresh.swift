public import AppKit
public import GhosttyKit
internal import QuartzCore
#if DEBUG
internal import CMUXDebugLog
#endif

extension TerminalSurface {
    /// Force a full size recalculation and surface redraw.
    @MainActor
    public func forceRefresh(reason: String = "unspecified") {
#if DEBUG
        let hasSurface = surface != nil
        let viewState: String
        if let view = attachedView {
            let inWindow = uiWindow != nil
            let bounds = view.bounds
            let metalOK = (view.layer as? CAMetalLayer) != nil
            viewState = "inWindow=\(inWindow) bounds=\(bounds) metalOK=\(metalOK) hasSurface=\(hasSurface)"
        } else {
            viewState = "NO_ATTACHED_VIEW hasSurface=\(hasSurface)"
        }
        logDebugEvent("forceRefresh: \(id) reason=\(reason) \(viewState)")
#endif
        guard let view = attachedView,
              let window = uiWindow,
              view.bounds.width > 0,
              view.bounds.height > 0 else {
            return
        }
#if DEBUG
        recordDebugForceRefresh()
#endif
        // Re-read self.surface before each ghostty call to guard against the surface
        // being freed during wake-from-sleep geometry reconciliation (issue #432).
        // The surface can be invalidated between calls when AppKit layout triggers
        // view lifecycle changes (e.g., forceRefreshSurface -> layout -> deinit -> free).

        // Reassert display id on topology churn (split close/reparent) before forcing a refresh.
        // This avoids a first-run stuck-vsync state where Ghostty believes vsync is active
        // but callbacks have not resumed for the current display.
        let displayID = (window.screen ?? NSScreen.main)?.displayID
#if DEBUG
        let accessReason = "forceRefresh.\(reason)"
#else
        let accessReason = "forceRefresh"
#endif
        guard let currentSurface = liveSurfaceForGhosttyAccess(reason: accessReason) else {
            return
        }
        if let displayID,
           displayID != 0 {
            ghostty_surface_set_display_id(currentSurface, displayID)
        }

        view.forceRefreshSurface()
#if DEBUG
        let refreshReason = "forceRefresh.refresh.\(reason)"
#else
        let refreshReason = "forceRefresh.refresh"
#endif
        guard let surface = liveSurfaceForGhosttyAccess(reason: refreshReason) else {
            return
        }
        ghostty_surface_refresh(surface)
    }
}
