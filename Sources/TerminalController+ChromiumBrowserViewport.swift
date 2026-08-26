import CmuxBrowser
import Foundation

extension TerminalController {
    nonisolated func v2BrowserViewportSet(params: [String: Any]) -> V2CallResult {
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

        var resolvedPanel: BrowserPanel?
        var workspaceID: UUID?
        var surfaceID: UUID?
        var isChromium = false
        v2MainSync {
            guard let tabManager = v2ResolveTabManager(params: params),
                  let context = v2ResolveBrowserPanelContext(
                    params: params,
                    tabManager: tabManager
                  ).context else {
                return
            }
            resolvedPanel = context.browserPanel
            workspaceID = context.workspaceId
            surfaceID = context.surfaceId
            isChromium = context.browserPanel.isChromiumBacked
        }
        if isChromium,
           let resolvedPanel,
           resolvedPanel.isChromiumIsolationPendingForAutomation {
            return .err(
                code: "not_connected",
                message: ChromiumBrowserDiagnostic.connectionClosed.message,
                data: nil
            )
        }
        guard isChromium,
              let resolvedPanel,
              !resolvedPanel.isChromiumIsolationPendingForAutomation,
              let workspaceID,
              let surfaceID else {
            return v2MainSync {
                v2BrowserViewportSetWKWebView(params: params)
            }
        }

        let nativeSize: CGSize = v2MainSync {
            let size = resolvedPanel.chromiumContentView?.bounds.size ?? .zero
            return size.width > 1 && size.height > 1
                ? size
                : CGSize(width: 1280, height: 720)
        }
        let targetWidth = requestedViewport?.width ?? max(1, Int(nativeSize.width.rounded(.down)))
        let targetHeight = requestedViewport?.height ?? max(1, Int(nativeSize.height.rounded(.down)))
        if case .failure(let error) = v2SetChromiumViewport(
            browserPanel: resolvedPanel,
            width: targetWidth,
            height: targetHeight
        ) {
            return .err(
                code: "timeout",
                message: v2ChromiumFailureMessage(operation: "viewport", error: error),
                data: nil
            )
        }

        guard let layout = BrowserViewportLayout(
            containerBounds: CGRect(origin: .zero, size: nativeSize),
            viewport: requestedViewport,
            pageZoom: 1
        ) else {
            return .err(
                code: "internal_error",
                message: String(
                    localized: "browser.viewport.error.layoutUnavailable",
                    defaultValue: "Browser viewport layout is unavailable"
                ),
                data: nil
            )
        }
        _ = v2MainSync {
            resolvedPanel.viewportModel.setViewport(requestedViewport)
        }
        return .ok([
            "workspace_id": workspaceID.uuidString,
            "workspace_ref": v2Ref(kind: .workspace, uuid: workspaceID),
            "surface_id": surfaceID.uuidString,
            "surface_ref": v2Ref(kind: .surface, uuid: surfaceID),
            "mode": layout.mode.rawValue,
            "width": Int(layout.bounds.width.rounded(.down)),
            "height": Int(layout.bounds.height.rounded(.down)),
            "display_width": layout.frame.width,
            "display_height": layout.frame.height,
            "scale": layout.scale,
            "exact": true,
            "pane_resized": false,
            "presentation": layout.mode == .emulated ? "aspect_fit" : "native",
            "engine": BrowserEngineKind.chromium.rawValue,
        ])
    }
}
