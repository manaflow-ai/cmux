import Foundation

/// Socket-worker adapters for the opt-in Mac browser bridge. The bridge itself
/// lives with the MobileHost composition root; this extension only converts
/// its value result into the existing v2 response envelope used by `cmux`.
extension TerminalController {
    /// The mobile-host verbs a browser grant may invoke. Keep this exact list
    /// aligned with ``MobileHostConnection/handleSubscriptionRPC(_:)`` and
    /// ``mobileHostHandleRPC(_:executionContext:)``; no prefix grants are used.
    nonisolated static func webBridgeAllows(method: String) -> Bool {
        switch method {
        case "mobile.host.status", "mobile.workspace.list",
             "events.stream", "events.cancel",
             "terminal.attach", "terminal.replay", "terminal.viewport", "terminal.input":
            return true
        default:
            return false
        }
    }

    /// Returns the browser-scoped request that reaches the terminal handlers.
    /// Caller-supplied viewport identities are always discarded; only requests
    /// carrying dimensions receive the authoritative connection-scoped id.
    nonisolated static func webClientBridgeScopedRequest(
        _ request: MobileHostRPCRequest,
        connectionID: UUID
    ) -> MobileHostRPCRequest {
        guard request.method == "terminal.replay"
            || request.method == "terminal.viewport"
            || request.method == "terminal.input" else {
            return request
        }
        var params = request.params
        let carriesViewport = params["viewport_columns"] != nil
            || params["viewport_rows"] != nil
            || request.method == "terminal.viewport"
        params.removeValue(forKey: "client_id")
        if carriesViewport {
            params["client_id"] = "web:\(connectionID.uuidString)"
        }
        return MobileHostRPCRequest(
            id: request.id,
            method: request.method,
            params: params,
            auth: request.auth
        )
    }

    /// Applies one browser-allowed RPC while holding its synchronous
    /// revocation fence. The v2 terminal bodies are intentionally synchronous
    /// at this boundary, so a grant revocation cannot overtake a mutation
    /// already admitted here.
    @MainActor
    func webClientBridgeHandleRPC(
        _ request: MobileHostRPCRequest,
        admission: WebClientGrantAdmission,
        connectionID: UUID
    ) -> MobileHostRPCResult {
        let scopedRequest = Self.webClientBridgeScopedRequest(
            request,
            connectionID: connectionID
        )
        return webClientBridgeHandleScopedRPC(scopedRequest, admission: admission)
    }

    /// Handles browser RPCs that can complete synchronously on the main actor.
    /// Byte replay uses ``webClientBridgeHandleRPCAsync`` so its export read is
    /// never performed while the admission lock is held.
    @MainActor
    private func webClientBridgeHandleScopedRPC(
        _ scopedRequest: MobileHostRPCRequest,
        admission: WebClientGrantAdmission
    ) -> MobileHostRPCResult {
        guard let result = admission.withValidAdmission({ () -> V2CallResult in
            switch scopedRequest.method {
            case "mobile.workspace.list":
                return v2MobileWorkspaceList(params: scopedRequest.params)
            case "terminal.replay":
                return v2MobileTerminalReplay(params: scopedRequest.params)
            case "terminal.viewport":
                return v2MobileTerminalViewport(params: scopedRequest.params)
            case "terminal.input":
                return v2MobileTerminalInput(params: scopedRequest.params)
            default:
                return .err(
                    code: "method_not_found",
                    message: String(
                        localized: "webClientBridge.error.methodNotExposed",
                        defaultValue: "Method is not exposed to browser clients"
                    ),
                    data: nil
                )
            }
        }) else {
            return .failure(MobileHostRPCError(
                code: "revoked",
                message: String(
                    localized: "webClientBridge.error.grantRevoked",
                    defaultValue: "Browser grant has been revoked"
                )
            ))
        }

        switch result {
        case let .ok(payload):
            return .ok(payload)
        case let .err(code, message, data):
            return .failure(MobileHostRPCError(code: code, message: message, data: data))
        }
    }

    /// Handles a browser request with an asynchronous byte-replay path. The
    /// admission fence is sampled before and after the detached export read,
    /// never held across its suspension point.
    @MainActor
    func webClientBridgeHandleRPCAsync(
        _ request: MobileHostRPCRequest,
        admission: WebClientGrantAdmission,
        connectionID: UUID
    ) async -> MobileHostRPCResult {
        let scopedRequest = Self.webClientBridgeScopedRequest(
            request,
            connectionID: connectionID
        )
        guard scopedRequest.method == "terminal.replay" else {
            return webClientBridgeHandleScopedRPC(scopedRequest, admission: admission)
        }
        guard let preparation = admission.withValidAdmission({
            self.prepareMobileTerminalReplay(params: scopedRequest.params)
        }) else {
            return .failure(MobileHostRPCError(
                code: "revoked",
                message: String(
                    localized: "webClientBridge.error.grantRevoked",
                    defaultValue: "Browser grant has been revoked"
                )
            ))
        }
        let result = await v2MobileTerminalReplayForWeb(
            params: scopedRequest.params,
            preparation: preparation
        )
        guard admission.withValidAdmission({ true }) != nil else {
            return .failure(MobileHostRPCError(
                code: "revoked",
                message: String(
                    localized: "webClientBridge.error.grantRevoked",
                    defaultValue: "Browser grant has been revoked"
                )
            ))
        }
        return Self.webBridgeV2Result(result)
    }

    nonisolated func webClientBridgeSocketResponse(
        method: String,
        id: Any?,
        params: [String: Any]
    ) -> String {
        switch method {
        case "web.bridge.start":
            let address: String
            if v2HasNonNullParam(params, "address") {
                guard let value = params["address"] as? String else {
                    return v2Error(
                        id: id,
                        code: "invalid_params",
                        message: String(
                            localized: "webClientBridge.error.addressMustBeString",
                            defaultValue: "address must be a string"
                        )
                    )
                }
                address = value
            } else {
                address = WebClientBridgeService.defaultAddress
            }
            let port: Int
            if v2HasNonNullParam(params, "port") {
                guard let value = v2StrictIntAny(params["port"]) else {
                    return v2Error(
                        id: id,
                        code: "invalid_params",
                        message: String(
                            localized: "webClientBridge.error.portMustBeInteger",
                            defaultValue: "port must be an integer"
                        )
                    )
                }
                port = value
            } else {
                port = WebClientBridgeService.defaultPort
            }
            return v2AsyncResultCall(id: id, timeoutSeconds: 10) {
                let result = await MobileHostService.shared.webClientBridgeService.start(
                    address: address,
                    port: port
                )
                return Self.webBridgeV2Result(result)
            }
        case "web.bridge.stop":
            return v2AsyncResultCall(id: id, timeoutSeconds: 10) {
                await MobileHostService.shared.webClientBridgeService.stop()
                return .ok(["stopped": true])
            }
        case "web.bridge.status":
            return v2AsyncResultCall(id: id, timeoutSeconds: 10) {
                Self.webBridgeV2Result(
                    await MobileHostService.shared.webClientBridgeService.status()
                )
            }
        case "web.bridge.grant.create":
            let label: String?
            if v2HasNonNullParam(params, "label") {
                guard let value = params["label"] as? String else {
                    return v2Error(
                        id: id,
                        code: "invalid_params",
                        message: String(
                            localized: "webClientBridge.error.labelMustBeString",
                            defaultValue: "label must be a string"
                        )
                    )
                }
                label = value
            } else {
                label = nil
            }
            return v2AsyncResultCall(id: id, timeoutSeconds: 10) {
                Self.webBridgeV2Result(
                    await MobileHostService.shared.webClientBridgeService.issueGrant(
                        label: label
                    )
                )
            }
        case "web.bridge.grant.list":
            return v2AsyncResultCall(id: id, timeoutSeconds: 10) {
                Self.webBridgeV2Result(
                    await MobileHostService.shared.webClientBridgeService.listGrants()
                )
            }
        case "web.bridge.grant.revoke":
            guard let rawID = params["grant_id"] as? String,
                  let grantID = UUID(uuidString: rawID) else {
                return v2Error(
                    id: id,
                    code: "invalid_params",
                    message: String(
                        localized: "webClientBridge.error.grantIDMustBeUUID",
                        defaultValue: "grant_id must be a UUID"
                    )
                )
            }
            return v2AsyncResultCall(id: id, timeoutSeconds: 10) {
                Self.webBridgeV2Result(
                    await MobileHostService.shared.webClientBridgeService.revokeGrant(id: grantID)
                )
            }
        default:
            return v2Error(
                id: id,
                code: "method_not_found",
                message: String(
                    localized: "webClientBridge.error.unknownMethod",
                    defaultValue: "Unknown web bridge method"
                )
            )
        }
    }

    private nonisolated static func webBridgeV2Result(
        _ result: MobileHostRPCResult
    ) -> V2CallResult {
        switch result {
        case let .ok(payload):
            return .ok(payload)
        case let .failure(error):
            return .err(code: error.code, message: error.message, data: error.data)
        }
    }
}
