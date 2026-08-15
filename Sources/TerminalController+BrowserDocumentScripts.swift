import Foundation
import WebKit

extension TerminalController {
    nonisolated func v2BrowserAddInitScript(params: [String: Any]) -> V2CallResult {
        guard let script = v2String(params, "script") ?? v2String(params, "content") else {
            return .err(code: "invalid_params", message: "Missing script", data: nil)
        }
        return v2BrowserWithPanelContext(params: params) { ctx in
            if v2MainSync({ ctx.browserPanel.isChromiumBacked }) {
                switch v2RegisterChromiumDocumentScript(
                    browserPanel: ctx.browserPanel,
                    source: script,
                    isStyle: false
                ) {
                case .failure(let error):
                    return .err(code: "cdp_error", message: error.localizedDescription, data: nil)
                case .success(let scriptsCount):
                    switch v2RunBrowserJavaScript(
                        ctx.webView,
                        browserPanel: ctx.browserPanel,
                        surfaceId: ctx.surfaceId,
                        script: script,
                        timeout: 10.0
                    ) {
                    case .failure(let message):
                        return .err(code: "js_error", message: message, data: nil)
                    case .success:
                        return .ok(v2BrowserPanelFields(ctx, adding: ["scripts": scriptsCount]))
                    }
                }
            }
            let scriptsCount = v2MainSync {
                let userScript = WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: false)
                return ctx.browserPanel.registerBrowserAutomationInitScript(userScript)
            }
            _ = v2RunBrowserJavaScript(ctx.webView, browserPanel: ctx.browserPanel, surfaceId: ctx.surfaceId, script: script, timeout: 10.0)

            return .ok(v2BrowserPanelFields(ctx, adding: ["scripts": scriptsCount]))
        }
    }

    nonisolated func v2BrowserAddScript(params: [String: Any]) -> V2CallResult {
        guard let script = v2String(params, "script") ?? v2String(params, "content") else {
            return .err(code: "invalid_params", message: "Missing script", data: nil)
        }
        return v2BrowserWithPanelContext(params: params) { ctx in
            switch v2RunBrowserJavaScript(ctx.webView, browserPanel: ctx.browserPanel, surfaceId: ctx.surfaceId, script: script, timeout: 10.0) {
            case .failure(let message):
                return .err(code: "js_error", message: message, data: nil)
            case .success(let value):
                return .ok(v2BrowserPanelFields(ctx, adding: ["value": v2NormalizeJSValue(value)]))
            }
        }
    }

    nonisolated func v2BrowserAddStyle(params: [String: Any]) -> V2CallResult {
        guard let css = v2String(params, "css") ?? v2String(params, "style") ?? v2String(params, "content") else {
            return .err(code: "invalid_params", message: "Missing css/style content", data: nil)
        }
        return v2BrowserWithPanelContext(params: params) { ctx in
            let cssLiteral = v2JSONLiteral(css)
            let source = """
            (() => {
              const el = document.createElement('style');
              el.textContent = String(\(cssLiteral));
              (document.head || document.documentElement || document.body).appendChild(el);
              return true;
            })()
            """

            if v2MainSync({ ctx.browserPanel.isChromiumBacked }) {
                switch v2RegisterChromiumDocumentScript(
                    browserPanel: ctx.browserPanel,
                    source: source,
                    isStyle: true
                ) {
                case .failure(let error):
                    return .err(code: "cdp_error", message: error.localizedDescription, data: nil)
                case .success(let stylesCount):
                    switch v2RunBrowserJavaScript(
                        ctx.webView,
                        browserPanel: ctx.browserPanel,
                        surfaceId: ctx.surfaceId,
                        script: source,
                        timeout: 10.0
                    ) {
                    case .failure(let message):
                        return .err(code: "js_error", message: message, data: nil)
                    case .success:
                        return .ok(v2BrowserPanelFields(ctx, adding: ["styles": stylesCount]))
                    }
                }
            }

            let stylesCount = v2MainSync {
                let userScript = WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false)
                return ctx.browserPanel.registerBrowserAutomationStyleScript(userScript)
            }
            _ = v2RunBrowserJavaScript(ctx.webView, browserPanel: ctx.browserPanel, surfaceId: ctx.surfaceId, script: source, timeout: 10.0)

            return .ok(v2BrowserPanelFields(ctx, adding: ["styles": stylesCount]))
        }
    }

}
