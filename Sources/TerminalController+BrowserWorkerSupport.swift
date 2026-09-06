import CmuxBrowser
import CmuxControlSocket
import Foundation

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
