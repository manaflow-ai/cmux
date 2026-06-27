import Foundation
public import CmuxControlSocket

extension BrowserAutomationController {
    /// Resolves one `browser.find.role`/`find.text`/`find.label`/`find.placeholder`/
    /// `find.alt`/`find.title`/`find.testid` request (the "with-script" family) by
    /// running the host-built `finderBody` against the live browser surface and
    /// decoding the match, returning the typed ``ControlBrowserFindResolution`` the
    /// app's `controlResolveBrowserFind` forwards to the worker.
    ///
    /// Byte-faithful lift of the former `TerminalController.v2ControlFindWithScript`
    /// body: the panel resolution hops to the main actor inside the host witness,
    /// the finder-script assembly (``BrowserControlService/findScript(finderBody:)``)
    /// and the result decoding stay here on the worker lane, and the JS evaluation
    /// runs through the host's worker-lane eval seam.
    ///
    /// `nonisolated`: runs on the socket worker lane (the JS evaluation blocks
    /// there); the only main-actor hop is inside the host witnesses.
    public nonisolated func controlFindWithScript(
        _ params: [String: Any],
        finderBody: String,
        host: any BrowserControlHosting
    ) -> ControlBrowserFindResolution {
        controlResolveFindOnPanel(params, host: host) { ctx in
            let script = control.findScript(finderBody: finderBody)
            switch host.v2RunBrowserJavaScript(
                ctx.webView,
                surfaceId: ctx.surfaceID,
                script: script,
                timeout: 5.0,
                useEval: true,
                onIsolatedWorldFallback: nil
            ) {
            case .failure(let message):
                return .jsError(message: message)
            case .success(let value):
                guard let dict = value as? [String: Any],
                      let ok = dict["ok"] as? Bool,
                      ok,
                      let selector = dict["selector"] as? String,
                      !selector.isEmpty else {
                    return .notFound(data: nil)
                }
                return controlFound(
                    ctx,
                    selector: selector,
                    tag: dict["tag"] as? String,
                    text: (dict["text"] as? String).map { .string($0) } ?? .omitted,
                    index: nil,
                    host: host
                )
            }
        }
    }

    /// Resolves a `browser.find.first` request: the byte-faithful lift of the
    /// former `TerminalController.v2ControlFindFirst` body.
    public nonisolated func controlFindFirst(
        _ params: [String: Any],
        rawSelector: String,
        host: any BrowserControlHosting
    ) -> ControlBrowserFindResolution {
        controlResolveFindSelectorOnPanel(params, rawSelector: rawSelector, host: host) { ctx, selector in
            let script = control.findFirstScript(selector: selector)
            switch host.v2RunBrowserJavaScript(
                ctx.webView,
                surfaceId: ctx.surfaceID,
                script: script,
                timeout: 5.0,
                useEval: true,
                onIsolatedWorldFallback: nil
            ) {
            case .failure(let message):
                return .jsError(message: message)
            case .success(let value):
                guard let dict = value as? [String: Any],
                      let ok = dict["ok"] as? Bool,
                      ok else {
                    return .notFound(data: ["selector": .string(selector)])
                }
                return controlFound(
                    ctx,
                    selector: selector,
                    tag: nil,
                    text: .orNull(dict["text"] as? String),
                    index: nil,
                    host: host
                )
            }
        }
    }

    /// Resolves a `browser.find.last` request: the byte-faithful lift of the
    /// former `TerminalController.v2ControlFindLast` body.
    public nonisolated func controlFindLast(
        _ params: [String: Any],
        rawSelector: String,
        host: any BrowserControlHosting
    ) -> ControlBrowserFindResolution {
        controlResolveFindSelectorOnPanel(params, rawSelector: rawSelector, host: host) { ctx, selector in
            let script = control.findLastScript(selector: selector)
            switch host.v2RunBrowserJavaScript(
                ctx.webView,
                surfaceId: ctx.surfaceID,
                script: script,
                timeout: 5.0,
                useEval: true,
                onIsolatedWorldFallback: nil
            ) {
            case .failure(let message):
                return .jsError(message: message)
            case .success(let value):
                guard let dict = value as? [String: Any],
                      let ok = dict["ok"] as? Bool,
                      ok,
                      let finalSelector = dict["selector"] as? String,
                      !finalSelector.isEmpty else {
                    return .notFound(data: ["selector": .string(selector)])
                }
                return controlFound(
                    ctx,
                    selector: finalSelector,
                    tag: nil,
                    text: .orNull(dict["text"] as? String),
                    index: nil,
                    host: host
                )
            }
        }
    }

    /// Resolves a `browser.find.nth` request: the byte-faithful lift of the
    /// former `TerminalController.v2ControlFindNth` body.
    public nonisolated func controlFindNth(
        _ params: [String: Any],
        rawSelector: String,
        index: Int,
        host: any BrowserControlHosting
    ) -> ControlBrowserFindResolution {
        controlResolveFindSelectorOnPanel(params, rawSelector: rawSelector, host: host) { ctx, selector in
            let script = control.findNthScript(selector: selector, index: index)
            switch host.v2RunBrowserJavaScript(
                ctx.webView,
                surfaceId: ctx.surfaceID,
                script: script,
                timeout: 5.0,
                useEval: true,
                onIsolatedWorldFallback: nil
            ) {
            case .failure(let message):
                return .jsError(message: message)
            case .success(let value):
                guard let dict = value as? [String: Any],
                      let ok = dict["ok"] as? Bool,
                      ok,
                      let finalSelector = dict["selector"] as? String,
                      !finalSelector.isEmpty else {
                    return .notFound(data: [
                        "selector": .string(selector),
                        "index": .int(Int64(index))
                    ])
                }
                return controlFound(
                    ctx,
                    selector: finalSelector,
                    tag: nil,
                    text: .orNull(dict["text"] as? String),
                    index: .orNull((dict["index"] as? NSNumber)?.intValue ?? dict["index"] as? Int),
                    host: host
                )
            }
        }
    }

    /// Resolves the browser panel (the shared `withBrowserPanelContext` host head)
    /// and runs `body` on it, translating a panel-head failure into
    /// `.panelUnavailable`. `body` returns the typed resolution directly.
    ///
    /// Byte-faithful lift of the former `TerminalController.v2ControlResolveOnPanel`.
    private nonisolated func controlResolveFindOnPanel(
        _ params: [String: Any],
        host: any BrowserControlHosting,
        _ body: (_ ctx: BrowserPanelContextSnapshot) -> ControlBrowserFindResolution
    ) -> ControlBrowserFindResolution {
        var resolution: ControlBrowserFindResolution = .notFound(data: nil)
        let panelResult = host.withBrowserPanelContext(params: params) { ctx in
            resolution = body(ctx)
            return .ok(NSNull())
        }
        if case let .err(code, message, data) = panelResult {
            return .panelUnavailable(.err(code: code, message: message, data: data.flatMap { JSONValue(foundationObject: $0) }))
        }
        return resolution
    }

    /// `controlResolveFindOnPanel` plus the shared `resolveSelector` step (the
    /// first/last/nth "Element reference not found" branch).
    ///
    /// Byte-faithful lift of the former
    /// `TerminalController.v2ControlResolveSelectorOnPanel`.
    private nonisolated func controlResolveFindSelectorOnPanel(
        _ params: [String: Any],
        rawSelector: String,
        host: any BrowserControlHosting,
        _ body: (_ ctx: BrowserPanelContextSnapshot, _ selector: String) -> ControlBrowserFindResolution
    ) -> ControlBrowserFindResolution {
        controlResolveFindOnPanel(params, host: host) { ctx in
            guard let selector = resolveSelector(rawSelector, surfaceId: ctx.surfaceID) else {
                return .selectorReferenceNotFound(rawSelector: rawSelector)
            }
            return body(ctx, selector)
        }
    }

    /// Builds a `.found` resolution from a resolved panel context, allocating the
    /// element ref against `selector` and computing the workspace/surface refs
    /// (the shared tail of every find body).
    ///
    /// Byte-faithful lift of the former `TerminalController.v2ControlFound`.
    private nonisolated func controlFound(
        _ ctx: BrowserPanelContextSnapshot,
        selector: String,
        tag: String?,
        text: ControlBrowserFindResultText,
        index: ControlBrowserFindResultIndex?,
        host: any BrowserControlHosting
    ) -> ControlBrowserFindResolution {
        let ref = allocateElementRef(surfaceId: ctx.surfaceID, selector: selector)
        return .found(ControlBrowserFoundElement(
            workspaceID: ctx.workspaceID,
            workspaceRef: (host.v2Ref(kind: .workspace, uuid: ctx.workspaceID) as? String) ?? ctx.workspaceID.uuidString,
            surfaceID: ctx.surfaceID,
            surfaceRef: (host.v2Ref(kind: .surface, uuid: ctx.surfaceID) as? String) ?? ctx.surfaceID.uuidString,
            selector: selector,
            elementRef: ref,
            tag: tag,
            text: text,
            index: index
        ))
    }
}
