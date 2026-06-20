public import Foundation
#if DEBUG
internal import CMUXDebugLog
#endif

/// Resolves and drives a React Grab toggle for one workspace.
///
/// TabManager owns the per-window workspace state and the keyboard-shortcut /
/// CLI entry points, but the toggle orchestration is browser behavior: arm or
/// clear the pasteback round-trip, focus the browser panel (clearing split zoom
/// first), request explicit web-view focus, then asynchronously ensure or
/// inject React Grab. This controller owns that logic; the app target adapts a
/// `Workspace` to ``ReactGrabWorkspaceContext`` and forwards through it.
///
/// The bodies are byte-faithful lifts of the former
/// `TabManager.toggleReactGrab(in:browserSurfaceId:returnTerminalSurfaceId:)`
/// and `TabManager.performReactGrabToggle(in:browserPanelId:returnTerminalPanelId:)`,
/// including the DEBUG `reactGrab.pasteback h1.focusRequestResult` log line.
///
/// `@MainActor` because every step mutates WebKit/AppKit state on the main
/// thread, matching the callers (the Cmd+Shift+G shortcut, the command socket,
/// the `cmux browser react-grab toggle` CLI) — state lives where its callers
/// live.
@MainActor
public final class ReactGrabController {
    /// Creates a controller. It holds no state; the workspace is passed per call.
    public init() {}

    /// Toggles React Grab for a workspace.
    ///
    /// When `browserSurfaceId`/`returnTerminalSurfaceId` are nil this mirrors
    /// the keyboard shortcut: it resolves the browser + return terminal from the
    /// focused panel layout. An explicit browser surface (must be a browser) or
    /// return terminal (must be a terminal) overrides that route.
    ///
    /// - Returns: the resolved browser surface id it acted on, or nil if it
    ///   could not resolve/act (so callers can report the actual browser surface
    ///   rather than the focused panel).
    @discardableResult
    public func toggleReactGrab(
        in workspace: any ReactGrabWorkspaceContext,
        browserSurfaceId: UUID?,
        returnTerminalSurfaceId: UUID?
    ) -> UUID? {
        let route = workspace.reactGrabRouteFromFocus()

        // Browser target: an explicit surface is authoritative (it must be a
        // browser, no fallback to a different browser); otherwise resolve the
        // route's browser from focus.
        let browserPanelId: UUID?
        if let explicit = browserSurfaceId {
            guard workspace.reactGrabBrowserActing(for: explicit) != nil else { return nil }
            browserPanelId = explicit
        } else {
            browserPanelId = route?.browserPanelId
        }
        guard let browserPanelId else { return nil }

        // Return terminal: an explicit return surface is authoritative (must be
        // a terminal in this workspace, no fallback) so pasteback never silently
        // goes to the wrong terminal. With no explicit return, adopt the route's
        // terminal only when the browser also came from the route (matching
        // shortcut semantics).
        let returnTerminalPanelId: UUID?
        if let explicit = returnTerminalSurfaceId {
            guard workspace.reactGrabPanelIsTerminal(explicit) else { return nil }
            returnTerminalPanelId = explicit
        } else if browserSurfaceId == nil {
            returnTerminalPanelId = route?.returnTerminalPanelId
        } else {
            returnTerminalPanelId = nil
        }

        let didToggle = performReactGrabToggle(
            in: workspace,
            browserPanelId: browserPanelId,
            returnTerminalPanelId: returnTerminalPanelId
        )
        return didToggle ? browserPanelId : nil
    }

    @discardableResult
    private func performReactGrabToggle(
        in workspace: any ReactGrabWorkspaceContext,
        browserPanelId: UUID,
        returnTerminalPanelId: UUID?
    ) -> Bool {
        guard let browserPanel = workspace.reactGrabBrowserActing(for: browserPanelId) else { return false }

        if let returnTerminalPanelId {
            browserPanel.armReactGrabRoundTrip(returnTo: returnTerminalPanelId)
        } else {
            browserPanel.clearReactGrabRoundTrip(reason: "shortcut.noReturnTarget")
        }

        if workspace.reactGrabFocusedPanelId != browserPanel.id {
            workspace.reactGrabClearSplitZoom()
            workspace.reactGrabFocusPanel(browserPanel.id)
        }

        let didRequestExplicitWebViewFocus = browserPanel.requestExplicitWebViewFocus()
#if DEBUG
        CMUXDebugLog.logDebugEvent(
            "reactGrab.pasteback h1.focusRequestResult " +
            "workspace=\(workspace.reactGrabWorkspaceId.uuidString.prefix(5)) " +
            "browser=\(browserPanel.id.uuidString.prefix(5)) " +
            "return=\(returnTerminalPanelId.map { String($0.uuidString.prefix(5)) } ?? "nil") " +
            "success=\(didRequestExplicitWebViewFocus ? 1 : 0)"
        )
#endif

        Task { @MainActor [weak browserPanel] in
            guard let browserPanel else { return }
            if returnTerminalPanelId != nil {
                await browserPanel.ensureReactGrabActive()
            } else {
                await browserPanel.toggleOrInjectReactGrab()
            }
            if !didRequestExplicitWebViewFocus {
                _ = browserPanel.requestExplicitWebViewFocus()
            }
        }
        return true
    }
}
