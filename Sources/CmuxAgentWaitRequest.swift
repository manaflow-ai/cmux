import CmuxControlSocket
import Dispatch
import Foundation

extension TerminalController {
    nonisolated func isAgentWaitRequest(_ line: String) -> Bool {
        guard line.hasPrefix("{"),
              let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        return object["method"] as? String == "agent.wait"
    }

    nonisolated func handleAgentWaitRequest(
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
                        localized: "socket.agentWait.error.invalidRequest",
                        defaultValue: "agent.wait requires a JSON object"
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
                        localized: "socket.agentWait.error.surfaceRequired",
                        defaultValue: "agent.wait requires surface_id"
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
        guard let surfaceID = v2MainSync({
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
        let prepare = {
            self.v2MainSync {
                AgentWaitCoordinator.Preparation(
                    afterSequence: CmuxEventBus.shared.latestSequence,
                    surface: self.agentWaitSurfaceSnapshot(surfaceID: surfaceID)
                )
            }
        }
        let waitResult = waitCoordinator.wait(
            until: until,
            timeoutMilliseconds: timeoutMilliseconds,
            prepare: prepare,
            routingSnapshot: { lifecycleSurfaceID in
                self.v2MainSync {
                    self.agentWaitSurfaceSnapshot(surfaceID: lifecycleSurfaceID)
                }
            }
        )
        revocationSource?.cancel()

        guard socketEventStreamAuthorizationIsCurrent(
                  authorizationGeneration,
                  passwordAuthorization: &waitPasswordAuthorization
              ),
              !Self.socketPeerClosed(socket) else {
            return
        }

        let response: String
        switch waitResult {
        case .success(let result):
            response = v2Ok(id: id, result: result.payload)
        case .failure(.surfaceNotFound):
            response = v2Error(
                id: id,
                code: "not_found",
                message: String(
                    localized: "socket.agentWait.error.surfaceNotFound",
                    defaultValue: "Surface not found"
                )
            )
        case .failure(.noAgent):
            response = v2Error(
                id: id,
                code: "no_agent",
                message: String(
                    localized: "socket.agentWait.error.noAgent",
                    defaultValue: "No agent lifecycle is recorded for this surface"
                )
            )
        case .failure(.liveLifecycleUnavailable):
            response = v2Error(
                id: id,
                code: "live_lifecycle_unavailable",
                message: String(
                    localized: "socket.agentWait.error.liveLifecycleUnavailable",
                    defaultValue: "Live agent lifecycle is unavailable for this surface"
                )
            )
        case .failure(.subscriptionClosed):
            response = v2Error(
                id: id,
                code: "wait_cancelled",
                message: String(
                    localized: "socket.agentWait.error.cancelled",
                    defaultValue: "Agent wait was cancelled"
                )
            )
        }
        writeAgentWaitResponse(response, socket: socket)
    }

    private nonisolated func writeAgentWaitResponse(_ response: String, socket: Int32) {
        _ = transport.writeAll(Data((response + "\n").utf8), to: socket)
    }

    private func agentWaitSurfaceSnapshot(surfaceID: UUID) -> AgentWaitSurfaceSnapshot? {
        if let dock = DockSplitStore.liveStores.first(where: { $0.containsPanel(surfaceID) }) {
            return dock.agentWaitSurfaceSnapshot(panelID: surfaceID)
        }
        let routing = ControlRoutingSelectors(
            hasWindowIDParam: false,
            windowID: nil,
            groupID: nil,
            workspaceID: nil,
            surfaceID: surfaceID,
            paneID: nil
        )
        guard let tabManager = resolveTabManager(routing: routing),
              let workspace = tabManager.tabs.first(where: {
                  $0.surfaceOwnershipTarget(for: surfaceID) != nil
              }) else {
            return nil
        }
        return workspace.agentWaitSurfaceSnapshot(surfaceID: surfaceID)
    }
}
