import AppKit
import Foundation
import WebKit

/// Window-Dock routing for the browser socket commands.
///
/// These resolvers decide when a browser command targets a per-window Dock
/// (owner `workspace_id`, the legacy Global Dock alias, or surface/pane
/// containment), reject explicitly contradictory Dock selectors, and build the
/// owner-anchored payloads Dock-scoped browser actions report. Split from
/// TerminalController.swift, which stays the generic browser command surface.
extension TerminalController {
    func v2ResolveWindowDockBrowserPanelContext(
        params: [String: Any],
        tabManager: TabManager
    ) -> (handled: Bool, context: V2BrowserPanelContext?, error: V2CallResult?) {
        let requestedWorkspaceID = v2UUID(params, "workspace_id")
        let requestedSurfaceID = v2UUID(params, "surface_id") ?? v2UUID(params, "tab_id")
        let requestedPaneID = v2UUID(params, "pane_id")

        let dockBySurface = requestedSurfaceID.flatMap { windowDockContainingPanel($0) }
        let dockByPane = requestedPaneID.flatMap { windowDockContainingPane($0) }
        let routesWindowDock = requestedWorkspaceID.map(AppDelegate.isWindowDockRoutingId) == true
            || dockBySurface != nil
            || dockByPane != nil
        guard routesWindowDock else {
            return (false, nil, nil)
        }

        // A supplied-but-unresolvable selector must fail closed instead of
        // degrading to the focused/owner Dock fallbacks below.
        if let err = v2RejectUnresolvedHandles(params, ["workspace_id", "window_id", "surface_id", "tab_id", "pane_id"]) {
            return (true, nil, err)
        }
        let dockByOwner = requestedWorkspaceID.flatMap { AppDelegate.shared?.existingWindowDock(forWindowId: $0) }
        // Explicit selectors that name two different windows' Docks fail closed
        // rather than silently acting on one of them. (The legacy alias pins no
        // specific Dock, so it never conflicts.)
        if windowDockSelectorsConflict(
            requestedWorkspaceID: requestedWorkspaceID,
            requestedWindowID: v2UUID(params, "window_id"),
            dockByOwner: dockByOwner,
            dockBySurface: dockBySurface,
            dockByPane: dockByPane
        ) {
            return (true, nil, .err(code: "invalid_params", message: dockConflictingRoutingSelectorsMessage(), data: nil))
        }
        guard let dock = dockBySurface ?? dockByPane ?? dockByOwner
                ?? AppDelegate.shared?.existingWindowDock(for: tabManager) else {
            return (true, nil, .err(code: "not_found", message: "No focused browser surface", data: nil))
        }

        let surfaceId: UUID?
        if let requestedSurfaceID {
            surfaceId = requestedSurfaceID
        } else if let requestedPaneID {
            guard let pane = dock.bonsplitController.allPaneIds.first(where: { $0.id == requestedPaneID }) else {
                return (true, nil, .err(code: "not_found", message: "Pane not found", data: ["pane_id": requestedPaneID.uuidString]))
            }
            guard let selectedTab = dock.bonsplitController.selectedTab(inPane: pane),
                  let selectedSurface = dock.panel(for: selectedTab.id)?.id else {
                return (true, nil, .err(code: "not_found", message: "Pane has no selected surface", data: ["pane_id": requestedPaneID.uuidString]))
            }
            surfaceId = selectedSurface
        } else {
            surfaceId = dock.focusedPanelId
        }

        guard let surfaceId else {
            return (true, nil, .err(code: "not_found", message: "No focused browser surface", data: nil))
        }
        guard let browserPanel = dock.browserPanel(for: surfaceId) else {
            return (true, nil, .err(code: "invalid_params", message: "Surface is not a browser", data: ["surface_id": surfaceId.uuidString]))
        }
        return (
            true,
            V2BrowserPanelContext(
                workspaceId: dock.workspaceId,
                surfaceId: surfaceId,
                browserPanel: browserPanel,
                webView: browserPanel.webView
            ),
            nil
        )
    }

    func v2ResolveWindowDockBrowserTabStore(
        params: [String: Any],
        tabManager: TabManager
    ) -> (handled: Bool, dock: DockSplitStore?, error: V2CallResult?) {
        let requestedWorkspaceID = v2UUID(params, "workspace_id")
        let requestedSurfaceID = v2UUID(params, "surface_id")
            ?? v2UUID(params, "tab_id")
            ?? v2UUID(params, "target_surface_id")
        let requestedPaneID = v2UUID(params, "pane_id")
            ?? v2UUID(params, "target_pane_id")

        let dockBySurface = requestedSurfaceID.flatMap { windowDockContainingPanel($0) }
        let dockByPane = requestedPaneID.flatMap { windowDockContainingPane($0) }
        let routesWindowDock = requestedWorkspaceID.map(AppDelegate.isWindowDockRoutingId) == true
            || dockBySurface != nil
            || dockByPane != nil
        guard routesWindowDock else {
            return (false, nil, nil)
        }

        // A supplied-but-unresolvable selector must fail closed instead of
        // degrading to the focused/owner Dock fallbacks below.
        if let err = v2RejectUnresolvedHandles(
            params,
            ["workspace_id", "window_id", "surface_id", "tab_id", "target_surface_id", "pane_id", "target_pane_id"]
        ) {
            return (true, nil, err)
        }
        let dockByOwner = requestedWorkspaceID.flatMap { AppDelegate.shared?.existingWindowDock(forWindowId: $0) }
        // Explicit selectors that name two different windows' Docks fail closed
        // rather than silently acting on one of them. (The legacy alias pins no
        // specific Dock, so it never conflicts.)
        if windowDockSelectorsConflict(
            requestedWorkspaceID: requestedWorkspaceID,
            requestedWindowID: v2UUID(params, "window_id"),
            dockByOwner: dockByOwner,
            dockBySurface: dockBySurface,
            dockByPane: dockByPane
        ) {
            return (true, nil, .err(code: "invalid_params", message: dockConflictingRoutingSelectorsMessage(), data: nil))
        }
        let dock = dockBySurface
            ?? dockByPane
            ?? dockByOwner
            ?? AppDelegate.shared?.windowDock(for: tabManager)
        guard let dock else {
            return (true, nil, .err(code: "not_found", message: "Workspace not found", data: nil))
        }
        return (true, dock, nil)
    }

    /// Whether explicit Dock selectors name more than one distinct window's
    /// Dock: owner `workspace_id` vs surface vs pane vs an explicit `window_id`
    /// (a window Dock's owner id IS its window id). A `workspace_id` that names
    /// a NON-Dock scope (neither the legacy alias nor a Dock owner) likewise
    /// contradicts a Dock resolved from surface/pane selectors. Browser CLI
    /// commands never inject the caller's workspace context (unlike e.g.
    /// `close-surface`), so this stays fail-closed without breaking the CLI.
    func windowDockSelectorsConflict(
        requestedWorkspaceID: UUID?,
        requestedWindowID: UUID?,
        dockByOwner: DockSplitStore?,
        dockBySurface: DockSplitStore?,
        dockByPane: DockSplitStore?
    ) -> Bool {
        let resolved = [dockByOwner, dockBySurface, dockByPane].compactMap { $0 }
        guard let first = resolved.first else { return false }
        if resolved.contains(where: { $0 !== first }) { return true }
        if let requestedWindowID, first.workspaceId != requestedWindowID { return true }
        if let requestedWorkspaceID,
           requestedWorkspaceID != AppDelegate.windowDockAliasWorkspaceId,
           dockByOwner == nil {
            return true
        }
        return false
    }

    /// Dock-scoped browser action payload. A window Dock's owner id IS its
    /// window id, so the reported window comes from the Dock itself rather than
    /// the routed `tabManager`, which can resolve a different window when the
    /// caller's injected context disagrees with the surface's home.
    func v2WindowDockBrowserActionPayload(
        _ ctx: V2BrowserPanelContext,
        extra: [String: Any] = [:]
    ) -> [String: Any] {
        var payload: [String: Any] = [
            "workspace_id": ctx.workspaceId.uuidString,
            "workspace_ref": v2Ref(kind: .workspace, uuid: ctx.workspaceId),
            "surface_id": ctx.surfaceId.uuidString,
            "surface_ref": v2Ref(kind: .surface, uuid: ctx.surfaceId),
            "window_id": ctx.workspaceId.uuidString,
            "window_ref": v2Ref(kind: .window, uuid: ctx.workspaceId)
        ]
        for (key, value) in extra { payload[key] = value }
        return payload
    }

    func closeWindowDockBrowserPanel(_ targetId: UUID, in dock: DockSplitStore) -> Bool {
        guard let tabId = dock.surfaceId(forPanelId: targetId) else { return false }
        dock.forceCloseDockTabIds.insert(tabId)
        let closed = dock.bonsplitController.closeTab(tabId)
        if !closed {
            dock.forceCloseDockTabIds.remove(tabId)
        }
        return closed
    }
}
