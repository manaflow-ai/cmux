import CmuxBrowser
import CmuxControlSocket
import Foundation
import WebKit

extension TerminalController {
    /// Returns the native-replay action represented by a browser keyboard method.
    nonisolated func browserKeyboardAction(
        for method: String
    ) -> BrowserKeyboardAction? {
        switch method {
        case "browser.press": return .press
        case "browser.keydown": return .keyDown
        case "browser.keyup": return .keyUp
        default: return nil
        }
    }

    /// Runs one mapped browser key through the MainActor/WebKit seam and encodes
    /// its typed result without parking the socket worker on a semaphore.
    nonisolated func v2BrowserKeyboardNativeResponse(
        request: ControlRequest,
        event: BrowserKeyboardEvent,
        action: BrowserKeyboardAction
    ) async -> String {
        let params = request.params.mapValues(\.foundationObject)
        let allowsFocusMutation = Self.socketCommandAllowsInAppFocusMutations(
            commandKey: request.method,
            isV2: true,
            params: params
        )
        let result = await CmuxAutomationInvocationContext.$focusAllowed.withValue(allowsFocusMutation) {
            await Task { @MainActor [weak self] in
                guard let self else {
                    return ControlCallResult.err(
                        code: "unavailable",
                        message: String(
                            localized: "cli.browser.error.operationFailed",
                            defaultValue: "Browser operation failed"
                        ),
                        data: nil
                    )
                }
                return await self.v2BrowserKeyboardNativeResult(
                    request: request,
                    event: event,
                    action: action
                )
            }.value
        }
        // Snapshot work is dispatched to the established blocking worker seam
        // after native delivery; the cooperative socket task never performs
        // v2BrowserAppendPostSnapshot directly.
        return await v2BrowserKeyboardResponseWithWorkerSnapshot(
            encodedResponse: Self.v2Encoder.response(id: request.id, result),
            request: request
        )
    }

    /// Adds an optional post-action snapshot on a dedicated blocking worker,
    /// keeping WebKit callback waits off the cooperative executor and main actor.
    private nonisolated func v2BrowserKeyboardResponseWithWorkerSnapshot(
        encodedResponse: String,
        request: ControlRequest
    ) async -> String {
        guard v2Bool(request.params.mapValues(\.foundationObject), "snapshot_after") == true,
              let result = Self.controlCallResult(fromEncodedResponse: encodedResponse),
              case .ok(let payload) = result,
              let payloadObject = payload.foundationObject as? [String: Any],
              let rawSurfaceID = payloadObject["surface_id"] as? String,
              let surfaceID = UUID(uuidString: rawSurfaceID) else {
            return encodedResponse
        }
        let params = request.params.mapValues(\.foundationObject)
        let snapshotPayload = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var mutablePayload = payloadObject
                self.v2BrowserAppendPostSnapshot(
                    params: params,
                    surfaceId: surfaceID,
                    payload: &mutablePayload
                )
                continuation.resume(returning: mutablePayload)
            }
        }
        guard let jsonPayload = JSONValue(foundationObject: snapshotPayload) else {
            return encodedResponse
        }
        return Self.v2Encoder.response(
            id: request.id,
            .ok(jsonPayload)
        )
    }

    /// Runs the native keyboard path from the synchronous socket adapter while
    /// keeping the main actor available for WebKit readiness and delivery.
    nonisolated func v2BrowserKeyboardNativeResponseSync(
        request: ControlRequest,
        event: BrowserKeyboardEvent,
        action: BrowserKeyboardAction
    ) -> String {
        let params = request.params.mapValues(\.foundationObject)
        let allowsFocusMutation = Self.socketCommandAllowsInAppFocusMutations(
            commandKey: request.method,
            isV2: true,
            params: params
        )
        let encodedResponse = CmuxAutomationInvocationContext.$focusAllowed.withValue(allowsFocusMutation) {
            v2AsyncResultCall(id: request.id?.foundationObject, timeoutSeconds: 15) {
                let result = await self.v2BrowserKeyboardNativeResult(
                    request: request,
                    event: event,
                    action: action
                )
                switch result {
                case .ok(let payload):
                    return .ok(payload.foundationObject)
                case .err(let code, let message, let data):
                    return .err(code: code, message: message, data: data?.foundationObject)
                }
            }
        }
        guard v2Bool(params, "snapshot_after") == true,
              let result = Self.controlCallResult(fromEncodedResponse: encodedResponse),
              case .ok(let payload) = result,
              let payloadObject = payload.foundationObject as? [String: Any],
              let rawSurfaceID = payloadObject["surface_id"] as? String,
              let surfaceID = UUID(uuidString: rawSurfaceID) else {
            return encodedResponse
        }
        var mutablePayload = payloadObject
        v2BrowserAppendPostSnapshot(
            params: params,
            surfaceId: surfaceID,
            payload: &mutablePayload
        )
        guard let jsonPayload = JSONValue(foundationObject: mutablePayload) else {
            return encodedResponse
        }
        return Self.v2Encoder.response(id: request.id, .ok(jsonPayload))
    }

    /// Executes a mapped browser key on the main actor after an asynchronous
    /// document-readiness wait. The typed result crosses back to the socket
    /// worker without carrying AppKit/WebKit objects or blocking a thread.
    @MainActor
    func v2BrowserKeyboardNativeResult(
        request: ControlRequest,
        event: BrowserKeyboardEvent,
        action: BrowserKeyboardAction
    ) async -> ControlCallResult {
        let params = request.params.mapValues(\.foundationObject)
        // The synchronous worker router refreshes handle aliases before every
        // browser command. Preserve that target-resolution invariant on this
        // asynchronous path without a second actor hop.
        v2RefreshKnownRefs()
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(
                code: "unavailable",
                message: String(
                    localized: "cli.browser.error.tabManagerUnavailable",
                    defaultValue: "Browser controls are unavailable"
                ),
                data: nil
            )
        }

        let resolved = v2ResolveBrowserPanelContext(
            params: params,
            tabManager: tabManager
        )
        if let error = resolved.error,
           case let .err(code, message, data) = error {
            return .err(
                code: code,
                message: message,
                data: data.flatMap(JSONValue.init(foundationObject:))
            )
        }
        guard let context = resolved.context else {
            return .err(
                code: "internal_error",
                message: String(
                    localized: "cli.browser.error.operationFailed",
                    defaultValue: "Browser operation failed"
                ),
                data: nil
            )
        }

        let expectedWebViewIdentifier = ObjectIdentifier(context.webView)
        switch await context.browserPanel.ensureAutomationDocumentReady(
            expectedWebViewIdentifier: expectedWebViewIdentifier,
            reason: "automation-keyboard"
        ) {
        case .timedOut:
            return .err(
                code: "timeout",
                message: String(
                    localized: "browser.automation.error.documentReadinessTimedOut",
                    defaultValue: "Timed out waiting for the browser document to become ready"
                ),
                data: .object(["surface_id": .string(context.surfaceId.uuidString)])
            )
        case .superseded:
            return .err(
                code: "stale_state",
                message: String(
                    localized: "browser.automation.error.superseded",
                    defaultValue: "The browser surface was already recovered. Retry the command."
                ),
                data: .object(["surface_id": .string(context.surfaceId.uuidString)])
            )
        case .cancelled:
            return .err(
                code: "cancelled",
                message: String(
                    localized: "cli.browser.error.operationFailed",
                    defaultValue: "Browser operation failed"
                ),
                data: nil
            )
        case .committed:
            break
        }

        guard context.browserPanel.webView === context.webView else {
            return .err(
                code: "stale_state",
                message: String(
                    localized: "browser.automation.error.superseded",
                    defaultValue: "The browser surface was already recovered. Retry the command."
                ),
                data: .object(["surface_id": .string(context.surfaceId.uuidString)])
            )
        }

        switch context.webView.replayBrowserKeyboardEvent(event, action: action) {
        case .delivered:
            let workspaceRef = v2EnsureHandleRef(kind: .workspace, uuid: context.workspaceId)
            let surfaceRef = v2EnsureHandleRef(kind: .surface, uuid: context.surfaceId)
            return .ok(.object([
                "workspace_id": .string(context.workspaceId.uuidString),
                "workspace_ref": .string(workspaceRef),
                "surface_id": .string(context.surfaceId.uuidString),
                "surface_ref": .string(surfaceRef)
            ]))
        case .unsupported, .eventCreationFailed:
            // This method is called only after the package reports a native
            // descriptor. Reaching either case means the AppKit adapter could
            // not honor the trusted-input contract; never downgrade to a DOM
            // KeyboardEvent here.
            return .err(
                code: "internal_error",
                message: String(
                    localized: "cli.browser.error.operationFailed",
                    defaultValue: "Browser operation failed"
                ),
                data: .object(["surface_id": .string(context.surfaceId.uuidString)])
            )
        }
    }

    nonisolated func v2BrowserPanelFields(
        _ context: V2BrowserPanelContext,
        adding fields: [String: Any] = [:]
    ) -> [String: Any] {
        var result: [String: Any] = [
            "workspace_id": context.workspaceId.uuidString,
            "workspace_ref": v2Ref(kind: .workspace, uuid: context.workspaceId),
            "surface_id": context.surfaceId.uuidString,
            "surface_ref": v2Ref(kind: .surface, uuid: context.surfaceId),
        ]
        fields.forEach { result[$0.key] = $0.value }
        return result
    }

    /// Resolves browser UI state on the main actor, then runs callback-waiting work on the socket worker.
    nonisolated func v2BrowserWithPanelContext(
        params: [String: Any],
        allowSoleBrowserFallback: Bool = false,
        _ body: (_ context: V2BrowserPanelContext) -> V2CallResult
    ) -> V2CallResult {
        var resolved: V2BrowserPanelContext?
        var failure = V2CallResult.err(
            code: "internal_error",
            message: String(
                localized: "cli.browser.error.operationFailed",
                defaultValue: "Browser operation failed"
            ),
            data: nil
        )
        v2MainSync {
            guard let tabManager = v2ResolveTabManager(params: params) else {
                failure = .err(
                    code: "unavailable",
                    message: String(
                        localized: "cli.browser.error.tabManagerUnavailable",
                        defaultValue: "Browser controls are unavailable"
                    ),
                    data: nil
                )
                return
            }
            let result = v2ResolveBrowserPanelContext(
                params: params,
                tabManager: tabManager,
                allowSoleBrowserFallback: allowSoleBrowserFallback
            )
            if let error = result.error {
                failure = error
                return
            }
            guard let context = result.context else { return }
            resolved = context
        }
        guard let resolved else { return failure }
        return body(resolved)
    }

    nonisolated func v2AwaitCallback<T>(
        timeout: TimeInterval,
        start: (@escaping (T) -> Void) -> Void
    ) -> T? {
        socketAwaitCallback(timeout: timeout, start: start)
    }
}

extension TerminalController {
    /// Returns a native text-input response for `browser.type`/`browser.fill`,
    /// or `nil` when the target is a control whose value must use the existing
    /// DOM compatibility path (for example date and range inputs).
    nonisolated func v2BrowserTextInputResponse(
        request: ControlRequest,
        replaceSelection: Bool
    ) async -> String? {
        let params = request.params.mapValues(\.foundationObject)
        let allowsFocusMutation = Self.socketCommandAllowsInAppFocusMutations(
            commandKey: request.method,
            isV2: true,
            params: params
        )
        let encodedResponse = await CmuxAutomationInvocationContext.$focusAllowed.withValue(allowsFocusMutation) {
            let task: Task<String?, Never> = Task { @MainActor [weak self] in
                guard let self else { return nil }
                return await self.v2BrowserTextInputResult(
                    request: request,
                    replaceSelection: replaceSelection
                )
            }
            return await task.value
        }
        guard let encodedResponse else { return nil }
        return await v2BrowserTextInputResponseWithWorkerSnapshot(
            encodedResponse: encodedResponse,
            request: request
        )
    }

    private nonisolated func v2BrowserTextInputResponseWithWorkerSnapshot(
        encodedResponse: String,
        request: ControlRequest
    ) async -> String {
        guard v2Bool(request.params.mapValues(\.foundationObject), "snapshot_after") == true,
              let result = Self.controlCallResult(fromEncodedResponse: encodedResponse),
              case .ok(let payload) = result,
              let payloadObject = payload.foundationObject as? [String: Any],
              let rawSurfaceID = payloadObject["surface_id"] as? String,
              let surfaceID = UUID(uuidString: rawSurfaceID) else {
            return encodedResponse
        }
        let params = request.params.mapValues(\.foundationObject)
        let snapshotPayload = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var mutablePayload = payloadObject
                self.v2BrowserAppendPostSnapshot(
                    params: params,
                    surfaceId: surfaceID,
                    payload: &mutablePayload
                )
                continuation.resume(returning: mutablePayload)
            }
        }
        guard let jsonPayload = JSONValue(foundationObject: snapshotPayload) else {
            return encodedResponse
        }
        return Self.v2Encoder.response(id: request.id, .ok(jsonPayload))
    }

    /// Performs one text action after focusing the target through the page's
    /// open shadow-root-aware DOM. Each character then travels through the
    /// same AppKit/WebKit native seam as `browser.press`, so framework code
    /// observes trusted key and input events instead of a DOM mutation.
    @MainActor
    private func v2BrowserTextInputResult(
        request: ControlRequest,
        replaceSelection: Bool
    ) async -> String? {
        v2RefreshKnownRefs()
        let params = request.params.mapValues(\.foundationObject)
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return Self.v2Encoder.response(
                id: request.id,
                .err(
                    code: "unavailable",
                    message: String(
                        localized: "cli.browser.error.tabManagerUnavailable",
                        defaultValue: "Browser controls are unavailable"
                    ),
                    data: nil
                )
            )
        }

        let resolved = v2ResolveBrowserPanelContext(params: params, tabManager: tabManager)
        if let error = resolved.error {
            return Self.v2Encoder.response(id: request.id, error)
        }
        guard let context = resolved.context else {
            return Self.v2Encoder.response(
                id: request.id,
                .err(
                    code: "not_found",
                    message: String(
                        localized: "cli.browser.error.noFocusedSurface",
                        defaultValue: "No focused browser surface"
                    ),
                    data: nil
                )
            )
        }

        let rawSelector = (params["selector"] as? String)
            ?? (params["sel"] as? String)
            ?? (params["element_ref"] as? String)
            ?? (params["ref"] as? String)
        let selector = rawSelector.flatMap {
            v2BrowserResolveSelector($0, surfaceId: context.surfaceId)
        }
        if rawSelector != nil, selector == nil {
            return Self.v2Encoder.response(
                id: request.id,
                .err(
                    code: "not_found",
                    message: String(
                        localized: "cli.browser.error.elementReferenceNotFound",
                        defaultValue: "Element reference not found"
                    ),
                    data: nil
                )
            )
        }

        guard let text = params["text"] as? String
                ?? params["value"] as? String else {
            return Self.v2Encoder.response(
                id: request.id,
                .err(
                    code: "invalid_params",
                    message: String(
                        localized: "cli.browser.error.missingTextValue",
                        defaultValue: "Missing text/value"
                    ),
                    data: nil
                )
            )
        }

        let browserControl = BrowserControlService()
        let selectorLiteral = selector.map(browserControl.jsonLiteral) ?? "null"
        let focusScript = """
            (() => {
              \(browserControl.elementQueryPrelude)
              const el = \(selectorLiteral) === null
                ? __cmuxDeepActiveElement()
                : __cmuxQuery(\(selectorLiteral));
              if (!el) return { ok: false, error: 'not_found' };
              if (\(selectorLiteral) !== null && typeof el.focus === 'function') {
                try { el.focus({ preventScroll: true }); } catch (_) { try { el.focus(); } catch (_) {} }
              }
              const tag = String(el.tagName || '').toLowerCase();
              const type = String(el.type || 'text').toLowerCase();
              const editable = !!el.isContentEditable
                || tag === 'textarea'
                || (tag === 'input' && !['button','checkbox','color','date','datetime-local','file','hidden','image','month','number','radio','range','reset','submit','time','week'].includes(type));
              return { ok: true, editable, value: ('value' in el) ? String(el.value || '') : String(el.textContent || '') };
            })()
            """
        let focusResult = await evaluateBrowserTextInputScript(
            focusScript,
            in: context.webView,
            panel: context.browserPanel
        )
        guard case .success(let rawFocus) = focusResult,
              let focus = rawFocus as? [String: Any],
              focus["ok"] as? Bool == true else {
            if selector != nil { return nil }
            return Self.v2Encoder.response(
                id: request.id,
                .err(
                    code: "not_found",
                    message: String(
                        localized: "cli.browser.error.noFocusedSurface",
                        defaultValue: "No focused browser surface"
                    ),
                    data: nil
                )
            )
        }
        guard context.browserPanel.webView === context.webView else {
            return Self.v2Encoder.response(
                id: request.id,
                .err(
                    code: "stale_state",
                    message: String(
                        localized: "browser.automation.error.superseded",
                        defaultValue: "The browser surface was already recovered. Retry the command."
                    ),
                    data: .object(["surface_id": .string(context.surfaceId.uuidString)])
                )
            )
        }
        guard focus["editable"] as? Bool == true else {
            // Native key replay is intentionally limited to text-capable
            // controls. Existing JS value handling remains correct for date,
            // range, and other specialized form controls.
            return selector == nil
                ? Self.v2Encoder.response(
                    id: request.id,
                    .err(
                        code: "invalid_params",
                        message: String(
                            localized: "cli.browser.error.focusedElementNotEditable",
                            defaultValue: "Focused browser element is not editable"
                        ),
                        data: nil
                    )
                )
                : nil
        }

        let nativeCharacters = text.map(String.init)
        guard nativeCharacters.allSatisfy({ BrowserKeyboardEvent(rawKey: $0)?.nativeKey != nil }) else {
            return nil
        }

        if replaceSelection {
            guard replayTextInputKey("Meta", in: context.webView, action: .keyDown),
                  replayTextInputKey("a", in: context.webView, action: .press),
                  replayTextInputKey("Meta", in: context.webView, action: .keyUp) else {
                return Self.v2Encoder.response(
                    id: request.id,
                    .err(
                        code: "internal_error",
                        message: String(
                            localized: "cli.browser.error.operationFailed",
                            defaultValue: "Browser operation failed"
                        ),
                        data: nil
                    )
                )
            }
            if nativeCharacters.isEmpty {
                guard replayTextInputKey("Backspace", in: context.webView, action: .press) else {
                    return Self.v2Encoder.response(
                        id: request.id,
                        .err(
                            code: "internal_error",
                            message: String(
                                localized: "cli.browser.error.operationFailed",
                                defaultValue: "Browser operation failed"
                            ),
                            data: nil
                        )
                    )
                }
            }
        }

        for character in nativeCharacters {
            guard replayTextInputKey(character, in: context.webView, action: .press) else {
                return Self.v2Encoder.response(
                    id: request.id,
                    .err(
                        code: "internal_error",
                        message: String(
                            localized: "cli.browser.error.operationFailed",
                            defaultValue: "Browser operation failed"
                        ),
                        data: nil
                    )
                )
            }
        }

        let surfaceID = context.surfaceId
        var payload: [String: Any] = [
            "workspace_id": context.workspaceId.uuidString,
            "workspace_ref": v2Ref(kind: .workspace, uuid: context.workspaceId),
            "surface_id": surfaceID.uuidString,
            "surface_ref": v2Ref(kind: .surface, uuid: surfaceID),
            "action": replaceSelection ? "fill" : "type"
        ]
        guard let jsonPayload = JSONValue(foundationObject: payload) else { return nil }
        return Self.v2Encoder.response(id: request.id, .ok(jsonPayload))
    }

    @MainActor
    private func evaluateBrowserTextInputScript(
        _ script: String,
        in webView: WKWebView,
        panel: BrowserPanel
    ) async -> Result<Any, Error> {
        let expectedWebViewIdentifier = ObjectIdentifier(webView)
        guard await panel.ensureAutomationDocumentReady(
            expectedWebViewIdentifier: expectedWebViewIdentifier,
            reason: "automation-text-input"
        ) == .committed else {
            return .failure(BrowserTextInputError.documentNotReady)
        }
        let gate = BrowserTextInputEvaluationGate()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Result<Any, Error>, Never>) in
                gate.install(continuation)
                webView.callAsyncJavaScript(
                    "return \(script)",
                    arguments: [:],
                    in: nil,
                    in: .page
                ) { result in
                    gate.finish(result)
                }
                Task { [gate] in
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    guard !Task.isCancelled else { return }
                    gate.finish(.failure(BrowserTextInputError.evaluationTimedOut))
                }
            }
        } onCancel: {
            gate.finish(.failure(BrowserTextInputError.cancelled))
        }
    }

    @MainActor
    private func replayTextInputKey(
        _ rawKey: String,
        in webView: WKWebView,
        action: BrowserKeyboardAction
    ) -> Bool {
        guard let event = BrowserKeyboardEvent(rawKey: rawKey) else { return false }
        switch webView.replayBrowserKeyboardEvent(event, action: action) {
        case .delivered: return true
        case .unsupported, .eventCreationFailed: return false
        }
    }
}

private enum BrowserTextInputError: Error {
    case documentNotReady
    case evaluationTimedOut
    case cancelled
}

/// Delivers a WebKit text-input evaluation result exactly once. WebKit may
/// invoke its callback after the timeout or task cancellation, so the
/// continuation cannot be resumed directly from either completion path.
private final class BrowserTextInputEvaluationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Result<Any, Error>, Never>?
    private var isFinished = false
    private var finishedResult: Result<Any, Error>?

    func install(_ continuation: CheckedContinuation<Result<Any, Error>, Never>) {
        lock.lock()
        let result = finishedResult
        if !isFinished {
            self.continuation = continuation
        }
        lock.unlock()

        if let result {
            continuation.resume(returning: result)
        }
    }

    func finish(_ result: Result<Any, Error>) {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        isFinished = true
        finishedResult = result
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()

        continuation?.resume(returning: result)
    }
}
