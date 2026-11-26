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
