import Foundation
import CmuxControlSocket

extension BrowserAutomationController {
    /// The byte-faithful `v2BrowserPress` / `v2BrowserKeyDown` / `v2BrowserKeyUp`
    /// core (they differ only by `script`, built app-side at the dispatch site
    /// from the bound key): resolves the browser panel through the host, evaluates
    /// `script` against the live `WKWebView` on the worker lane, and on success
    /// captures the workspace/surface identity plus the optional post-action
    /// snapshot out through a `var` (the panel-head sentinel `.ok` is ignored),
    /// matching the legacy branch structure exactly.
    ///
    /// `nonisolated`: runs on the socket worker lane; the panel resolution and the
    /// JS evaluation hop to the main actor inside the host witnesses.
    public nonisolated func resolveKeyEvent(
        params: [String: Any],
        script: String,
        host: any BrowserControlHosting
    ) -> BrowserPanelActionOutcome {
        var success: ControlBrowserPanelActionSuccess?
        let panelResult = host.withBrowserPanelContext(params: params) { ctx in
            let surfaceId = ctx.surfaceID
            switch host.v2RunBrowserJavaScript(
                ctx.webView,
                surfaceId: surfaceId,
                script: script,
                timeout: 5.0,
                useEval: true,
                onIsolatedWorldFallback: nil
            ) {
            case .failure(let message):
                return .err(code: "js_error", message: message, data: nil)
            case .success:
                var postPayload: [String: Any] = [:]
                appendPostSnapshot(params: params, surfaceId: surfaceId, payload: &postPayload, host: host)
                success = ControlBrowserPanelActionSuccess(
                    workspaceID: ctx.workspaceID,
                    workspaceRef: (host.v2Ref(kind: .workspace, uuid: ctx.workspaceID) as? String) ?? ctx.workspaceID.uuidString,
                    surfaceID: surfaceId,
                    surfaceRef: (host.v2Ref(kind: .surface, uuid: surfaceId) as? String) ?? surfaceId.uuidString,
                    postSnapshot: postPayload.compactMapValues { JSONValue(foundationObject: $0) }
                )
                return .ok(NSNull())
            }
        }
        if let success {
            return .success(success)
        }
        return .failure(panelResult)
    }

    /// The byte-faithful `v2BrowserScroll` core: resolves the browser panel and the
    /// optional selector/element-ref, builds the window-vs-element scroll script,
    /// evaluates it on the worker lane, and shapes the not-found diagnostics, the
    /// ref-not-found echo, the `js_error` branch, and the success identity + optional
    /// post-action snapshot exactly as the legacy body did (the success captured out
    /// through a `var` like ``resolveKeyEvent(params:script:host:)``).
    public nonisolated func resolveScroll(
        params: [String: Any],
        dx: Int,
        dy: Int,
        host: any BrowserControlHosting
    ) -> BrowserPanelActionOutcome {
        let selectorRaw = selector(in: params)

        var success: ControlBrowserPanelActionSuccess?
        let panelResult = host.withBrowserPanelContext(params: params) { ctx in
            let surfaceId = ctx.surfaceID
            let selector = selectorRaw.flatMap { resolveSelector($0, surfaceId: surfaceId) }
            if selectorRaw != nil && selector == nil {
                return .err(code: "not_found", message: "Element reference not found", data: ["selector": selectorRaw ?? ""])
            }

            let script: String
            if let selector {
                script = control.scrollElementScript(selectorLiteral: jsonLiteral(selector), dx: dx, dy: dy)
            } else {
                script = control.scrollWindowScript(dx: dx, dy: dy)
            }

            switch host.v2RunBrowserJavaScript(
                ctx.webView,
                surfaceId: surfaceId,
                script: script,
                timeout: 5.0,
                useEval: true,
                onIsolatedWorldFallback: nil
            ) {
            case .failure(let message):
                return .err(code: "js_error", message: message, data: nil)
            case .success(let value):
                if let dict = value as? [String: Any],
                   let ok = dict["ok"] as? Bool,
                   !ok,
                   let errorText = dict["error"] as? String,
                   errorText == "not_found" {
                    if let selector {
                        return browserElementNotFoundResult(
                            actionName: "scroll",
                            selector: selector,
                            attempts: 1,
                            surfaceId: surfaceId,
                            webView: ctx.webView,
                            host: host
                        )
                    }
                    return .err(code: "not_found", message: "Element not found", data: ["selector": selector ?? ""])
                }
                var postPayload: [String: Any] = [:]
                appendPostSnapshot(params: params, surfaceId: surfaceId, payload: &postPayload, host: host)
                success = ControlBrowserPanelActionSuccess(
                    workspaceID: ctx.workspaceID,
                    workspaceRef: (host.v2Ref(kind: .workspace, uuid: ctx.workspaceID) as? String) ?? ctx.workspaceID.uuidString,
                    surfaceID: surfaceId,
                    surfaceRef: (host.v2Ref(kind: .surface, uuid: surfaceId) as? String) ?? surfaceId.uuidString,
                    postSnapshot: postPayload.compactMapValues { JSONValue(foundationObject: $0) }
                )
                return .ok(NSNull())
            }
        }
        if let success {
            return .success(success)
        }
        return .failure(panelResult)
    }
}
