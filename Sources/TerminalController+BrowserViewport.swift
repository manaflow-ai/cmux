import CmuxBrowser
import CmuxControlSocket
import Foundation

extension TerminalController {
    func v2BrowserViewportSetWKWebView(params: [String: Any]) -> V2CallResult {
        let requestedViewport: BrowserViewport?
        if params["reset"] as? Bool == true || params["mode"] as? String == "native" {
            requestedViewport = nil
        } else {
            guard let width = v2StrictInt(params, "width"),
                  let height = v2StrictInt(params, "height") else {
                return .err(
                    code: "invalid_params",
                    message: String(
                        localized: "browser.viewport.error.requiresIntegerDimensions",
                        defaultValue: "browser.viewport.set requires integer width and height"
                    ),
                    data: nil
                )
            }
            guard let viewport = BrowserViewport(width: width, height: height) else {
                return .err(
                    code: "invalid_params",
                    message: String(
                        localized: "browser.viewport.error.dimensionsOutOfRange",
                        defaultValue: "Viewport dimensions must be between 1 and 4096"
                    ),
                    data: [
                        "minimum": BrowserViewport.minimumDimension,
                        "maximum": BrowserViewport.maximumDimension,
                        "width": width,
                        "height": height,
                    ]
                )
            }
            requestedViewport = viewport
        }

        return v2BrowserWithPanel(params: params) { workspaceId, surfaceId, panel in
            if let enginePage = panel.automationEnginePage {
                return v2BrowserViewportSetEngine(
                    enginePage,
                    viewport: requestedViewport,
                    workspaceId: workspaceId,
                    surfaceId: surfaceId
                )
            }
            let layout: BrowserViewportLayout
            switch panel.setAutomationViewport(requestedViewport) {
            case .success(let appliedLayout):
                layout = appliedLayout
            case .failure(let error):
                return v2BrowserAutomationViewportError(error)
            }

            return .ok([
                "workspace_id": workspaceId.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: workspaceId),
                "surface_id": surfaceId.uuidString,
                "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                "mode": layout.mode.rawValue,
                "width": Int(layout.bounds.width.rounded(.down)),
                "height": Int(layout.bounds.height.rounded(.down)),
                "display_width": layout.frame.width,
                "display_height": layout.frame.height,
                "scale": layout.scale,
                "exact": true,
                "pane_resized": false,
                "presentation": layout.mode == .emulated ? "aspect_fit" : "native",
            ])
        }
    }

    /// `browser.viewport.set` from the socket worker. A WebKit panel runs the
    /// unchanged main-actor body in one hop; a Chromium panel applies the
    /// override over DevTools and replies once it is in place, with the
    /// engine's error if it fails.
    nonisolated func v2BrowserViewportSetOnWorker(params: [String: Any]) -> V2CallResult {
        let engineTarget: (page: any BrowserPage, workspaceId: UUID, surfaceId: UUID, refusal: V2CallResult?)? = v2MainSync {
            guard let tabManager = v2ResolveTabManager(params: params),
                  let context = v2ResolveBrowserPanelContext(params: params, tabManager: tabManager).context,
                  let page = context.browserPanel.automationEnginePage else {
                return nil
            }
            return (
                page,
                context.workspaceId,
                context.surfaceId,
                v2EngineAgentRefusal(context.browserPanel, surfaceId: context.surfaceId)
            )
        }
        guard let engineTarget else {
            return v2MainSync { v2BrowserViewportSetWKWebView(params: params) }
        }
        if let refusal = engineTarget.refusal {
            return refusal
        }
        let requested: BrowserViewport?
        if params["reset"] as? Bool == true || params["mode"] as? String == "native" {
            requested = nil
        } else {
            guard let width = v2StrictInt(params, "width"),
                  let height = v2StrictInt(params, "height"),
                  let viewport = BrowserViewport(width: width, height: height) else {
                // The main-actor body owns the parameter errors' exact shape.
                return v2MainSync { v2BrowserViewportSetWKWebView(params: params) }
            }
            requested = viewport
        }
        let page = engineTarget.page
        let outcome: Result<Void, any Error>? = v2AwaitEnginePage(timeout: 5.0) {
            do {
                try await BrowserPageAutomation(page: page).setViewportOverride(
                    width: requested?.width,
                    height: requested?.height
                )
                return .success(())
            } catch {
                return .failure(error)
            }
        }
        switch outcome {
        case nil:
            return v2EngineAutomationTimeout(surfaceId: engineTarget.surfaceId)
        case .failure(let error):
            return v2EngineAutomationError(error, surfaceId: engineTarget.surfaceId)
        case .success:
            var payload: [String: Any] = [
                "workspace_id": engineTarget.workspaceId.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: engineTarget.workspaceId),
                "surface_id": engineTarget.surfaceId.uuidString,
                "surface_ref": v2Ref(kind: .surface, uuid: engineTarget.surfaceId),
                "mode": requested == nil ? "native" : "emulated",
                "exact": true,
                "pane_resized": false,
                "presentation": requested == nil ? "native" : "device_metrics",
            ]
            if let requested {
                payload["width"] = requested.width
                payload["height"] = requested.height
            }
            return .ok(payload)
        }
    }

    /// `browser.viewport.set` on a page that emulates its own viewport
    /// (Chromium device metrics): the page lays out at exactly the requested
    /// CSS size while the pane keeps its size, like WebKit's emulated mode.
    ///
    /// This method runs on the main actor, which must not wait for the engine,
    /// so the override is sent without waiting for its reply. DevTools handles
    /// one page's commands in order, so a later screenshot or script sees the
    /// new viewport.
    private func v2BrowserViewportSetEngine(
        _ page: any BrowserPage,
        viewport: BrowserViewport?,
        workspaceId: UUID,
        surfaceId: UUID
    ) -> V2CallResult {
        let automation = BrowserPageAutomation(page: page)
        guard automation.supportsViewportOverride else {
            return .err(
                code: "not_supported",
                message: BrowserAutomationPageError.unsupported("viewport emulation").message,
                data: ["surface_id": surfaceId.uuidString]
            )
        }
        let width = viewport.map { Int($0.width) }
        let height = viewport.map { Int($0.height) }
        Task { @MainActor in
            do {
                try await automation.setViewportOverride(width: width, height: height)
            } catch {
#if DEBUG
                cmuxDebugLog("browser.viewport.engine.failed surface=\(surfaceId.uuidString.prefix(5)) error=\(error)")
#endif
            }
        }
        var payload: [String: Any] = [
            "workspace_id": workspaceId.uuidString,
            "workspace_ref": v2Ref(kind: .workspace, uuid: workspaceId),
            "surface_id": surfaceId.uuidString,
            "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
            "mode": viewport == nil ? "native" : "emulated",
            "exact": true,
            "pane_resized": false,
            "presentation": viewport == nil ? "native" : "device_metrics",
        ]
        if let width, let height {
            payload["width"] = width
            payload["height"] = height
        }
        return .ok(payload)
    }

    func v2BrowserAutomationViewportError(
        _ error: BrowserAutomationViewportError
    ) -> V2CallResult {
        switch error {
        case .attachedBrowserInspector:
            return .err(
                code: "invalid_state",
                message: String(
                    localized: "browser.viewport.error.attachedBrowserInspector",
                    defaultValue: "Close or detach the browser inspector before changing the browser viewport"
                ),
                data: [
                    "reason": "attached_browser_inspector",
                    "supported_modes": ["native", "emulated"],
                ]
            )
        case .elementFullscreen:
            return .err(
                code: "invalid_state",
                message: String(
                    localized: "browser.viewport.error.elementFullscreen",
                    defaultValue: "Exit browser element fullscreen before changing the browser viewport"
                ),
                data: [
                    "reason": "element_fullscreen",
                    "supported_modes": ["native", "emulated"],
                ]
            )
        case let .renderGeometryTooLarge(requestedPageZoom, maximumPageZoom):
            return v2BrowserViewportRenderLimitError(
                requestedPageZoom: requestedPageZoom,
                maximumPageZoom: maximumPageZoom
            )
        }
    }

    func v2BrowserViewportRenderLimitError(
        requestedPageZoom: Double,
        maximumPageZoom: Double
    ) -> V2CallResult {
        let limits = BrowserViewportRenderLimits.standard
        return .err(
            code: "invalid_params",
            message: String(
                localized: "browser.viewport.error.renderGeometryTooLarge",
                defaultValue: "Viewport and page zoom exceed browser render limits"
            ),
            data: [
                "reason": "viewport_zoom_render_geometry_too_large",
                "requested_page_zoom": requestedPageZoom,
                "maximum_page_zoom": maximumPageZoom,
                "maximum_render_dimension": limits.maximumDimension,
                "maximum_render_area": limits.maximumArea,
            ]
        )
    }
}
