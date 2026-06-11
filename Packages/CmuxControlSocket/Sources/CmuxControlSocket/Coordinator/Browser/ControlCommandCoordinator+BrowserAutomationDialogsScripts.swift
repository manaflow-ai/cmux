internal import Foundation

/// The browser dialog bodies (`browser.dialog.accept`/`dismiss`) and script
/// injection bodies (`browser.addinitscript`/`addscript`/`addstyle`), with
/// their injected JS byte-identical to the legacy originals.
extension ControlCommandCoordinator {
    /// `browser.dialog.accept` / `browser.dialog.dismiss` — resolve the
    /// oldest hooked page dialog (the page-world `__cmuxDialogQueue`), and
    /// record confirm/prompt defaults for future dialogs.
    func browserDialogRespond(_ params: [String: JSONValue], accept: Bool) -> ControlCallResult {
        return withBrowserPanel(params) { workspaceID, surfaceID in
            browserContext?.controlBrowserEnsureTelemetryHooks(surfaceID: surfaceID)
            browserContext?.controlBrowserEnsureDialogHooks(surfaceID: surfaceID)
            let text = string(params, "text") ?? string(params, "prompt_text")
            let acceptLiteral = accept ? "true" : "false"
            let textLiteral = text.map(browserJSONLiteral) ?? "null"
            let script = """
            (() => {
              const q = window.__cmuxDialogQueue || [];
              if (!q.length) return { ok: false, error: 'not_found' };
              const entry = q.shift();
              if (entry.type === 'confirm') {
                window.__cmuxDialogDefaults = window.__cmuxDialogDefaults || { confirm: false, prompt: null };
                window.__cmuxDialogDefaults.confirm = \(acceptLiteral);
              }
              if (entry.type === 'prompt') {
                window.__cmuxDialogDefaults = window.__cmuxDialogDefaults || { confirm: false, prompt: null };
                if (\(acceptLiteral)) {
                  window.__cmuxDialogDefaults.prompt = \(textLiteral);
                } else {
                  window.__cmuxDialogDefaults.prompt = null;
                }
              }
              return { ok: true, dialog: entry, remaining: q.length };
            })()
            """

            let outcome = browserContext?.controlBrowserRunPageScript(
                surfaceID: surfaceID,
                script: script,
                timeout: 5.0
            ) ?? .failure("Browser operation failed")

            switch outcome {
            case .failure(let message):
                return .err(code: "js_error", message: message, data: nil)
            case .success(let value):
                guard let dict = browserScriptObject(value),
                      browserExactBool(dict["ok"]) == true else {
                    let pending = browserPendingDialogSummaries(surfaceID: surfaceID)
                    return .err(
                        code: "not_found",
                        message: "No pending dialog",
                        data: .object(["pending": .array(pending)])
                    )
                }

                var payload = browserIdentityPayload(workspaceID: workspaceID, surfaceID: surfaceID)
                payload["accepted"] = .bool(accept)
                payload["dialog"] = dict["dialog"] ?? .null
                payload["remaining"] = dict["remaining"] ?? .null
                return .ok(.object(payload))
            }
        }
    }

    /// The pending native-dialog summaries for the `No pending dialog`
    /// diagnostic (was `v2BrowserPendingDialogs`; keys identical).
    func browserPendingDialogSummaries(surfaceID: UUID) -> [JSONValue] {
        let queue = browserContext?.controlBrowserAutomationState.pendingDialogs(forSurface: surfaceID) ?? []
        return queue.enumerated().map { index, dialog in
            .object([
                "index": .int(Int64(index)),
                "type": .string(dialog.kind),
                "message": .string(dialog.message),
                "default_text": orNull(dialog.defaultText),
            ])
        }
    }

    /// Pops the oldest pending native dialog for a surface and runs its
    /// app-side completion handler through the seam (the redesigned twin of
    /// the legacy `v2BrowserPopDialog` + responder closure; like the
    /// original pop, no command body calls it yet — the native queue exists
    /// for the WKUIDelegate enqueue path).
    @discardableResult
    func browserResolveNextNativeDialog(surfaceID: UUID, accept: Bool, text: String?) -> ControlBrowserPendingDialog? {
        guard let browserContext,
              let dialog = browserContext.controlBrowserAutomationState.popDialog(forSurface: surfaceID) else {
            return nil
        }
        _ = browserContext.controlBrowserResolvePendingDialog(dialogID: dialog.dialogID, accept: accept, text: text)
        return dialog
    }

    /// `browser.addinitscript` — record a script, install it as a persistent
    /// document-start user script, and run it once now.
    func browserAddInitScript(_ params: [String: JSONValue]) -> ControlCallResult {
        guard let script = string(params, "script") ?? string(params, "content") else {
            return .err(code: "invalid_params", message: "Missing script", data: nil)
        }
        return withBrowserPanel(params) { workspaceID, surfaceID in
            let scriptCount = browserContext?.controlBrowserAutomationState
                .appendInitScript(script, forSurface: surfaceID) ?? 0

            browserContext?.controlBrowserAddPersistentUserScript(surfaceID: surfaceID, source: script)
            _ = browserRunScript(surfaceID: surfaceID, script: script, timeout: 10.0)

            var payload = browserIdentityPayload(workspaceID: workspaceID, surfaceID: surfaceID)
            payload["scripts"] = .int(Int64(scriptCount))
            return .ok(.object(payload))
        }
    }

    /// `browser.addscript` — run a script once and return its value.
    func browserAddScript(_ params: [String: JSONValue]) -> ControlCallResult {
        guard let script = string(params, "script") ?? string(params, "content") else {
            return .err(code: "invalid_params", message: "Missing script", data: nil)
        }
        return withBrowserPanel(params) { workspaceID, surfaceID in
            switch browserRunScript(surfaceID: surfaceID, script: script, timeout: 10.0) {
            case .failure(let message):
                return .err(code: "js_error", message: message, data: nil)
            case .success(let value):
                var payload = browserIdentityPayload(workspaceID: workspaceID, surfaceID: surfaceID)
                payload["value"] = browserPayloadValue(value)
                return .ok(.object(payload))
            }
        }
    }

    /// `browser.addstyle` — record a stylesheet, install it as a persistent
    /// document-start user script, and apply it once now.
    func browserAddStyle(_ params: [String: JSONValue]) -> ControlCallResult {
        guard let css = string(params, "css") ?? string(params, "style") ?? string(params, "content") else {
            return .err(code: "invalid_params", message: "Missing css/style content", data: nil)
        }
        return withBrowserPanel(params) { workspaceID, surfaceID in
            let styleCount = browserContext?.controlBrowserAutomationState
                .appendInitStyle(css, forSurface: surfaceID) ?? 0

            let cssLiteral = browserJSONLiteral(css)
            let source = """
            (() => {
              const el = document.createElement('style');
              el.textContent = String(\(cssLiteral));
              (document.head || document.documentElement || document.body).appendChild(el);
              return true;
            })()
            """

            browserContext?.controlBrowserAddPersistentUserScript(surfaceID: surfaceID, source: source)
            _ = browserRunScript(surfaceID: surfaceID, script: source, timeout: 10.0)

            var payload = browserIdentityPayload(workspaceID: workspaceID, surfaceID: surfaceID)
            payload["styles"] = .int(Int64(styleCount))
            return .ok(.object(payload))
        }
    }
}
