import CmuxControlSocket
import Dispatch
import Foundation

extension TerminalController {
    private enum AgentSendAndWaitSetupOutcome {
        case waitFailure(AgentWaitError)
        case sendFailure(ControlCallResult)
        case ready(
            surface: AgentWaitSurfaceSnapshot,
            subscription: CmuxEventSubscriptionSnapshot,
            minimumEventSequence: Int64,
            sendResult: ControlCallResult
        )
    }

    nonisolated func isAgentSendAndWaitRequest(_ line: String) -> Bool {
        guard line.hasPrefix("{"),
              let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        return object["method"] as? String == "agent.send_and_wait"
    }

    /// Handles the atomic `agent.send_and_wait` request used by
    /// `cmux send --wait-until`. The lifecycle subscription is admitted before
    /// the shared `surface.send_text` mutation, and the wait ignores every
    /// event whose sequence predates completion of that mutation.
    nonisolated func handleAgentSendAndWaitRequest(
        _ line: String,
        socket: Int32,
        authorizationGeneration: UInt64,
        authorizationRevocationSignal: SocketAuthorizationRevocationSignal,
        passwordAuthorization: SocketPasswordAuthorization
    ) {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            writeAgentWaitResponse(
                v2Error(
                    id: nil,
                    code: "invalid_request",
                    message: String(
                        localized: "socket.agentSendAndWait.error.invalidRequest",
                        defaultValue: "agent.send_and_wait requires a JSON object"
                    )
                ),
                socket: socket
            )
            return
        }

        let id = object["id"]
        let params = object["params"] as? [String: Any] ?? [:]
        guard let rawSurfaceID = params["surface_id"] as? String,
              !rawSurfaceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            writeAgentWaitResponse(
                v2Error(
                    id: id,
                    code: "invalid_params",
                    message: String(
                        localized: "socket.agentSendAndWait.error.surfaceRequired",
                        defaultValue: "agent.send_and_wait requires surface_id"
                    )
                ),
                socket: socket
            )
            return
        }
        guard params["text"] is String else {
            writeAgentWaitResponse(
                v2Error(
                    id: id,
                    code: "invalid_params",
                    message: String(
                        localized: "socket.agentSendAndWait.error.textRequired",
                        defaultValue: "agent.send_and_wait requires text"
                    )
                ),
                socket: socket
            )
            return
        }
        guard let rawUntil = params["until"] as? String,
              let until = AgentWaitUntil(cliValue: rawUntil) else {
            writeAgentWaitResponse(
                v2Error(
                    id: id,
                    code: "invalid_params",
                    message: String(
                        localized: "socket.agentWait.error.invalidUntil",
                        defaultValue: "agent.wait until must be idle, needs-input, or exit"
                    )
                ),
                socket: socket
            )
            return
        }

        let timeoutMilliseconds: Int64?
        if params["timeout_ms"] != nil {
            guard let parsedTimeout = v2StrictInt(params, "timeout_ms"), parsedTimeout >= 0 else {
                writeAgentWaitResponse(
                    v2Error(
                        id: id,
                        code: "invalid_params",
                        message: String(
                            localized: "socket.agentWait.error.invalidTimeout",
                            defaultValue: "agent.wait timeout_ms must be a non-negative integer"
                        )
                    ),
                    socket: socket
                )
                return
            }
            timeoutMilliseconds = Int64(parsedTimeout)
        } else {
            timeoutMilliseconds = nil
        }

        let normalizedSurfaceID = rawSurfaceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let requestedSurfaceID = v2MainSync({
            UUID(uuidString: normalizedSurfaceID) ?? self.v2ResolveHandleRef(normalizedSurfaceID)
        }) else {
            writeAgentWaitResponse(
                v2Error(
                    id: id,
                    code: "not_found",
                    message: String(
                        localized: "socket.agentWait.error.surfaceNotFound",
                        defaultValue: "Surface not found"
                    )
                ),
                socket: socket
            )
            return
        }

        var sendParams: [String: JSONValue] = [:]
        for (key, value) in params where key != "until" && key != "timeout_ms" {
            guard let typedValue = JSONValue(foundationObject: value) else {
                writeAgentWaitResponse(
                    v2Error(
                        id: id,
                        code: "invalid_params",
                        message: String(
                            localized: "socket.agentSendAndWait.error.invalidRequest",
                            defaultValue: "agent.send_and_wait contains an invalid parameter"
                        )
                    ),
                    socket: socket
                )
                return
            }
            sendParams[key] = typedValue
        }
        // Resolve refs once above, then force the shared send path to use the
        // exact UUID that was pinned for the atomic operation.
        sendParams["surface_id"] = .string(requestedSurfaceID.uuidString)
        let sendRequest = ControlRequest(
            id: nil,
            method: "surface.send_text",
            params: sendParams
        )

        var waitPasswordAuthorization = passwordAuthorization
        var revocationSource: (any DispatchSourceRead)?
        let waitCoordinator = AgentWaitCoordinator(
            eventBus: .shared,
            onSubscribe: { subscription in
                revocationSource = self.socketLongLivedRequestRevocationSource(
                    authorizationRevocationSignal,
                    subscription: subscription
                )
            },
            shouldContinue: {
                self.socketEventStreamAuthorizationIsCurrent(
                    authorizationGeneration,
                    passwordAuthorization: &waitPasswordAuthorization
                ) && !Self.socketPeerClosed(socket)
            }
        )

        let initialPreparation: (afterSequence: Int64, surface: AgentWaitSurfaceSnapshot?) = v2MainSync {
            let afterSequence = CmuxEventBus.shared.latestSequence
            return (
                afterSequence,
                self.agentWaitSurfaceSnapshot(surfaceID: requestedSurfaceID)
            )
        }
        guard let initialSurface = initialPreparation.surface else {
            writeAgentWaitResponse(
                agentWaitErrorResponse(id: id, error: .surfaceNotFound),
                socket: socket
            )
            return
        }
        guard initialSurface.hasAuthoritativeLiveLifecycle else {
            writeAgentWaitResponse(
                agentWaitErrorResponse(id: id, error: .liveLifecycleUnavailable),
                socket: socket
            )
            return
        }
        guard initialSurface.occupant != nil else {
            writeAgentWaitResponse(
                agentWaitErrorResponse(id: id, error: .noAgent),
                socket: socket
            )
            return
        }

        let subscription = waitCoordinator.subscribe(
            surfaceID: initialSurface.surfaceID,
            afterSequence: initialPreparation.afterSequence
        )
        let setup: AgentSendAndWaitSetupOutcome = v2MainSync {
            guard !subscription.subscription.isClosed else {
                return .waitFailure(.subscriptionClosed)
            }
            if let resume = subscription.ack["resume"] as? [String: Any],
               resume["gap"] as? Bool == true {
                return .waitFailure(.subscriptionClosed)
            }
            guard let surface = self.agentWaitSurfaceSnapshot(surfaceID: requestedSurfaceID) else {
                return .waitFailure(.surfaceNotFound)
            }
            // A move changes the lifecycle event's surface scope. Refuse to
            // send rather than completing a wait against the old scope.
            guard surface.surfaceID == initialSurface.surfaceID else {
                return .waitFailure(.surfaceNotFound)
            }
            guard surface.hasAuthoritativeLiveLifecycle else {
                return .waitFailure(.liveLifecycleUnavailable)
            }
            guard surface.occupant != nil else {
                return .waitFailure(.noAgent)
            }
            // Capture the sequence immediately before delivery. The lifecycle
            // transition caused by this send has a later sequence and must be
            // eligible; anything already queued before delivery is stale for
            // this atomic operation.
            let sendBaselineSequence = CmuxEventBus.shared.latestSequence
            guard let sendResult = self.controlCommandCoordinator.handle(sendRequest) else {
                return .sendFailure(
                    .err(
                        code: "internal_error",
                        message: String(
                            localized: "socket.error.unknownMethod",
                            defaultValue: "Unknown method"
                        ),
                        data: nil
                    )
                )
            }
            if case .err = sendResult {
                return .sendFailure(sendResult)
            }
            return .ready(
                surface: surface,
                subscription: subscription,
                minimumEventSequence: sendBaselineSequence,
                sendResult: sendResult
            )
        }

        guard socketEventStreamAuthorizationIsCurrent(
                  authorizationGeneration,
                  passwordAuthorization: &waitPasswordAuthorization
              ),
              !Self.socketPeerClosed(socket) else {
            CmuxEventBus.shared.unsubscribe(subscription.subscription)
            revocationSource?.cancel()
            return
        }

        let response: String
        switch setup {
        case .waitFailure(let error):
            CmuxEventBus.shared.unsubscribe(subscription.subscription)
            response = agentWaitErrorResponse(id: id, error: error)
        case .sendFailure(let sendResult):
            CmuxEventBus.shared.unsubscribe(subscription.subscription)
            response = agentSendAndWaitControlResultResponse(id: id, result: sendResult)
        case let .ready(surface, admittedSubscription, minimumEventSequence, sendResult):
            let waitResult = waitCoordinator.wait(
                until: until,
                timeoutMilliseconds: timeoutMilliseconds,
                surface: surface,
                subscriptionSnapshot: admittedSubscription,
                minimumEventSequence: minimumEventSequence,
                requirePostSubscriptionEvent: true,
                routingSnapshot: { lifecycleSurfaceID in
                    self.v2MainSync {
                        self.agentWaitSurfaceSnapshot(surfaceID: lifecycleSurfaceID)
                    }
                }
            )
            switch waitResult {
            case .success(let result):
                response = v2Ok(
                    id: id,
                    result: agentSendAndWaitPayload(result, sendResult: sendResult)
                )
            case .failure(let error):
                response = agentWaitErrorResponse(
                    id: id,
                    error: error,
                    data: ["sent": true]
                )
            }
        }
        revocationSource?.cancel()

        guard socketEventStreamAuthorizationIsCurrent(
                  authorizationGeneration,
                  passwordAuthorization: &waitPasswordAuthorization
              ),
              !Self.socketPeerClosed(socket) else {
            return
        }
        writeAgentWaitResponse(response, socket: socket)
    }

    private nonisolated func agentSendAndWaitControlResultResponse(
        id: Any?,
        result: ControlCallResult
    ) -> String {
        switch result {
        case .ok(let payload):
            return v2Ok(id: id, result: payload.foundationObject)
        case .err(let code, let message, let data):
            return v2Error(
                id: id,
                code: code,
                message: message,
                data: data?.foundationObject
            )
        }
    }

    private nonisolated func agentSendAndWaitPayload(
        _ waitResult: AgentWaitResult,
        sendResult: ControlCallResult
    ) -> [String: Any] {
        var payload = waitResult.payload
        if case .ok(let sendPayload) = sendResult,
           case .object(let values) = sendPayload {
            for (key, value) in values where payload[key] == nil {
                payload[key] = value.foundationObject
            }
        }
        payload["sent"] = true
        return payload
    }

}
