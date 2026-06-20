internal import Foundation

/// The main-actor browser-tab lifecycle commands (`browser.tab.new`,
/// `browser.tab.list`, `browser.tab.switch`, `browser.tab.close`), lifted
/// byte-faithfully from the former `TerminalController.v2BrowserTabNew` /
/// `v2BrowserTabList` / `v2BrowserTabSwitch` / `v2BrowserTabClose` bodies.
///
/// The coordinator owns the param-to-routing parsing and builds each payload
/// directly as a ``JSONValue`` (the typed twin of the legacy `[String: Any]`
/// dictionaries; the resulting Foundation object is identical, so the encoded
/// wire bytes match). The app-coupled work (the `v2ResolveWorkspace` head, the
/// ordered-panel enumeration, the target-pane/index/surface resolution, browser
/// surface creation, focus, and close-recording-history) runs behind the
/// ``ControlBrowserContext`` seam and returns a typed Sendable resolution.
///
/// These commands run on the main actor: like `browser.open_split` they create
/// or mutate `BrowserPanel` state synchronously and are NOT on the socket-worker
/// lane (no blocking page-JS waits), so the `@MainActor` coordinator can host
/// them. Unlike the action/panel commands, the legacy tab payloads carry NO
/// `window_id`/`window_ref` — only `workspace_*` plus the surface/pane fields —
/// so this handler shapes the identity payload by hand to preserve that exactly.
extension ControlCommandCoordinator {
    /// Runs one decoded request if it belongs to the browser-tab lifecycle domain
    /// this coordinator owns, returning the typed result; returns `nil` otherwise
    /// so the caller can fall through.
    ///
    /// - Parameter request: The decoded request envelope.
    /// - Returns: The command result, or `nil` if not owned here.
    func handleBrowserTabs(_ request: ControlRequest) -> ControlCallResult? {
        switch request.method {
        case "browser.tab.new":
            return browserTabNew(request.params)
        case "browser.tab.list":
            return browserTabList(request.params)
        case "browser.tab.switch":
            return browserTabSwitch(request.params)
        case "browser.tab.close":
            return browserTabClose(request.params)
        default:
            return nil
        }
    }

    /// The browser-domain view of the seam. `ControlCommandContext` already
    /// refines ``ControlBrowserContext``, so this is a plain widening of the
    /// stored `context` (no downcast).
    private var browserTabsContext: (any ControlBrowserContext)? {
        context
    }

    // MARK: - tab.list

    /// `browser.tab.list` — list the workspace's ordered browser tabs.
    private func browserTabList(_ params: [String: JSONValue]) -> ControlCallResult {
        let resolution = browserTabsContext?.controlBrowserTabList(
            params: params,
            routing: routingSelectors(params)
        ) ?? .tabManagerUnavailable
        switch resolution {
        case .tabManagerUnavailable:
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        case .workspaceNotFound:
            return .err(code: "not_found", message: "Workspace not found", data: nil)
        case .resolved(let workspaceID, let focusedSurfaceID, let tabs):
            let rows: [JSONValue] = tabs.map { row in
                .object([
                    "id": .string(row.surfaceID.uuidString),
                    "ref": ref(.surface, row.surfaceID),
                    "index": .int(Int64(row.index)),
                    "title": .string(row.title),
                    "url": .string(row.url),
                    "focused": .bool(row.focused),
                    "pane_id": orNull(row.paneID?.uuidString),
                    "pane_ref": ref(.pane, row.paneID),
                ])
            }
            return .ok(.object([
                "workspace_id": .string(workspaceID.uuidString),
                "workspace_ref": ref(.workspace, workspaceID),
                "surface_id": orNull(focusedSurfaceID?.uuidString),
                "surface_ref": ref(.surface, focusedSurfaceID),
                "tabs": .array(rows),
            ]))
        }
    }

    // MARK: - tab.new

    /// `browser.tab.new` — create a browser tab in the target pane.
    private func browserTabNew(_ params: [String: JSONValue]) -> ControlCallResult {
        let resolution = browserTabsContext?.controlBrowserTabNew(
            params: params,
            routing: routingSelectors(params),
            rawURLString: string(params, "url")
        ) ?? .tabManagerUnavailable
        switch resolution {
        case .tabManagerUnavailable:
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        case .disabledExternalInvalidURL(let rawURL):
            return .err(
                code: "invalid_params",
                message: "Invalid URL",
                data: .object(["url": .string(rawURL)])
            )
        case .disabledExternalNoURL:
            return .err(code: "browser_disabled", message: "cmux browser is disabled", data: nil)
        case .disabledExternalOpenFailed(let url):
            return .err(
                code: "external_open_failed",
                message: "Failed to open URL externally",
                data: .object(["url": .string(url)])
            )
        case .disabledExternalOpened(let windowID, let url):
            return .ok(.object([
                "window_id": orNull(windowID?.uuidString),
                "window_ref": ref(.window, windowID),
                "workspace_id": orNull(nil),
                "workspace_ref": ref(.workspace, nil),
                "pane_id": orNull(nil),
                "pane_ref": ref(.pane, nil),
                "surface_id": orNull(nil),
                "surface_ref": ref(.surface, nil),
                "created_split": .bool(false),
                "opened_externally": .bool(true),
                "browser_disabled": .bool(true),
                "placement_strategy": .string("external_browser_disabled"),
                "url": .string(url),
            ]))
        case .workspaceNotFound:
            return .err(code: "not_found", message: "Workspace not found", data: nil)
        case .paneNotFound:
            return .err(code: "not_found", message: "Target pane not found", data: nil)
        case .createFailed:
            return .err(code: "internal_error", message: "Failed to create browser tab", data: nil)
        case .resolved(let workspaceID, let paneID, let surfaceID, let url):
            return .ok(.object([
                "workspace_id": .string(workspaceID.uuidString),
                "workspace_ref": ref(.workspace, workspaceID),
                "pane_id": .string(paneID.uuidString),
                "pane_ref": ref(.pane, paneID),
                "surface_id": .string(surfaceID.uuidString),
                "surface_ref": ref(.surface, surfaceID),
                "url": .string(url),
            ]))
        }
    }

    // MARK: - tab.switch

    /// `browser.tab.switch` — focus a target browser tab.
    private func browserTabSwitch(_ params: [String: JSONValue]) -> ControlCallResult {
        let resolution = browserTabsContext?.controlBrowserTabSwitch(
            params: params,
            routing: routingSelectors(params)
        ) ?? .tabManagerUnavailable
        switch resolution {
        case .tabManagerUnavailable:
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        case .workspaceNotFound:
            return .err(code: "not_found", message: "Workspace not found", data: nil)
        case .browserTabNotFound:
            return .err(code: "not_found", message: "Browser tab not found", data: nil)
        case .resolved(let workspaceID, let surfaceID):
            return .ok(.object([
                "workspace_id": .string(workspaceID.uuidString),
                "workspace_ref": ref(.workspace, workspaceID),
                "surface_id": .string(surfaceID.uuidString),
                "surface_ref": ref(.surface, surfaceID),
            ]))
        }
    }

    // MARK: - tab.close

    /// `browser.tab.close` — close a target browser tab, recording history.
    private func browserTabClose(_ params: [String: JSONValue]) -> ControlCallResult {
        let resolution = browserTabsContext?.controlBrowserTabClose(
            params: params,
            routing: routingSelectors(params)
        ) ?? .tabManagerUnavailable
        switch resolution {
        case .tabManagerUnavailable:
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        case .workspaceNotFound:
            return .err(code: "not_found", message: "Workspace not found", data: nil)
        case .noBrowserTabs:
            return .err(code: "not_found", message: "No browser tabs", data: nil)
        case .browserTabNotFound:
            return .err(code: "not_found", message: "Browser tab not found", data: nil)
        case .cannotCloseLastSurface:
            return .err(code: "invalid_state", message: "Cannot close the last surface", data: nil)
        case .closeFailed(let surfaceID):
            return .err(
                code: "internal_error",
                message: "Failed to close browser tab",
                data: .object(["surface_id": .string(surfaceID.uuidString)])
            )
        case .resolved(let workspaceID, let surfaceID):
            return .ok(.object([
                "workspace_id": .string(workspaceID.uuidString),
                "workspace_ref": ref(.workspace, workspaceID),
                "surface_id": .string(surfaceID.uuidString),
                "surface_ref": ref(.surface, surfaceID),
            ]))
        }
    }
}
