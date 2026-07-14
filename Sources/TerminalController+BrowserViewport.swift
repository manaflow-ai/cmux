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
            guard let layout = panel.setAutomationViewport(requestedViewport) else {
                return .err(
                    code: "invalid_state",
                    message: String(
                        localized: "browser.viewport.error.attachedWebInspector",
                        defaultValue: "Close or detach Web Inspector before changing the browser viewport"
                    ),
                    data: [
                        "reason": "attached_web_inspector",
                        "supported_modes": ["native", "emulated"],
                    ]
                )
            }

            return .ok([
                "workspace_id": workspaceId.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: workspaceId),
                "surface_id": surfaceId.uuidString,
                "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                "mode": layout.mode.rawValue,
                "width": Int(layout.bounds.width.rounded()),
                "height": Int(layout.bounds.height.rounded()),
                "display_width": layout.frame.width,
                "display_height": layout.frame.height,
                "scale": layout.scale,
                "exact": true,
                "pane_resized": false,
                "presentation": layout.mode == .emulated ? "aspect_fit" : "native",
            ])
        }
    }
}
