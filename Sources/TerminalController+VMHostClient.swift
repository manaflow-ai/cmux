import CmuxControlSocket
import Foundation

/// Connections from Cloud VMs over the private-network listener
/// (`VMHostListenerCoordinator`). Same wire protocol as the local control
/// socket, but a different trust model: the peer is a machine the user owns,
/// not a process on this Mac, so the local same-UID and password gates do not
/// apply and `VMHostAccessPolicy` does instead.
extension TerminalController {
    struct VMHostConnectionContext: Sendable {
        let peerAddress: String
        let networkCIDRs: [String]
    }

    /// Admit one accepted machine connection to the bounded worker pool.
    nonisolated func spawnVMHostClientHandler(socket clientSocket: Int32, context: VMHostConnectionContext) async {
        guard VMHostAccessPolicy.sourceIsAllowed(peer: context.peerAddress, networkCIDRs: context.networkCIDRs) else {
            #if DEBUG
            cmuxDebugLog("vmhost.connection.denied peer=\(context.peerAddress) reason=source")
            #endif
            close(clientSocket)
            return
        }
        let submission = await socketClientWorkerPool.submit { [weak self] in
            guard let self else {
                close(clientSocket)
                return
            }
            await self.handleVMHostClientAsync(clientSocket, context: context)
        } onDrop: {
            close(clientSocket)
        }
        _ = submission
    }

    private nonisolated func handleVMHostClientAsync(_ socket: Int32, context: VMHostConnectionContext) async {
        defer {
            shutdown(socket, SHUT_RDWR)
            close(socket)
        }
        let lineReader = ControlClientAsyncLineReader(
            socket: socket,
            maximumBufferedBytes: VMHostAccessPolicy.maxRequestLineBytes
        )
        let writer = ControlClientAsyncWriter(socket: socket)
        let rateLimiter = ControlClientRateLimiter()
        defer {
            lineReader.cancel()
            writer.cancel()
        }
        while let line = await lineReader.nextLine(shouldContinueReading: { true }) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard trimmed.hasPrefix("{") else {
                // v1 text commands carry no token and are never admitted.
                _ = await writer.writeAll(Data((Self.socketClientAccessDeniedResponse + "\n").utf8))
                return
            }
            let request: ControlRequest
            switch Self.v2Parser.request(fromLine: trimmed) {
            case .failure(let parseError):
                guard await writer.writeAll(Data((Self.v2Encoder.response(for: parseError) + "\n").utf8)) else { return }
                continue
            case .success(let parsed):
                request = parsed
            }
            let authorization = authorizeVMHostRequest(request, context: context)
            if let errorResponse = authorization.errorResponse {
                guard await writer.writeAll(Data((errorResponse + "\n").utf8)) else { return }
                continue
            }
            if case .limited(let retryAfterMilliseconds) = await rateLimiter.admit(method: request.method) {
                let response = v2Error(
                    id: request.id?.foundationObject,
                    code: "rate_limited",
                    message: "Too many requests; retry after \(retryAfterMilliseconds) ms"
                )
                guard await writer.writeAll(Data((response + "\n").utf8)) else { return }
                continue
            }
            guard let sanitizedLine = Self.vmHostRequestLine(authorization.request) else {
                let response = v2Error(id: request.id?.foundationObject, code: "invalid_params", message: "Request could not be re-encoded")
                guard await writer.writeAll(Data((response + "\n").utf8)) else { return }
                continue
            }
            let response = await processCommandUsingSocketExecutionPolicyAsync(sanitizedLine)
            if let response {
                guard await writer.writeAll(Data((response + "\n").utf8)) else { return }
            }
        }
    }

    /// Re-encode a sanitized request as one JSON line for the shared v2
    /// dispatcher. The token parameter has already been removed.
    nonisolated static func vmHostRequestLine(_ request: ControlRequest) -> String? {
        var object: [String: Any] = [
            "method": request.method,
            "params": request.params.mapValues(\.foundationObject),
        ]
        if let id = request.id?.foundationObject { object["id"] = id }
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let line = String(data: data, encoding: .utf8) else { return nil }
        return line
    }

    private struct VMHostAuthorizationSnapshot: Sendable {
        let workspaceIDs: Set<UUID>
        let surfaceIDs: Set<UUID>
    }

    /// The Cloud VM host gate. A request must carry a token this Mac minted
    /// for a machine, name only an allowed verb, and name only workspaces and
    /// surfaces bound to that machine. Returns the request with the token
    /// stripped, or an encoded error.
    nonisolated func authorizeVMHostRequest(
        _ request: ControlRequest,
        context: VMHostConnectionContext
    ) -> RemoteRelayAuthorizationResult {
        let foundationParams = request.params.mapValues(\.foundationObject)
        guard let token = foundationParams[VMHostAccessPolicy.tokenParamKey] as? String, !token.isEmpty else {
            return deniedVMHostRequest(request, code: "vm_host_authentication_required", message: "Machine token is missing")
        }
        guard let vmID = VMHostListenerCoordinator.tokens.vmID(forToken: token) else {
            return deniedVMHostRequest(request, code: "vm_host_authentication_failed", message: "Machine token is not recognized")
        }
        guard VMHostAccessPolicy.allowedMethods.contains(request.method) else {
            return deniedVMHostRequest(request, code: "vm_host_method_denied", message: "Method is not permitted from a machine")
        }

        let snapshot: VMHostAuthorizationSnapshot = v2MainSync(commandKey: request.method) {
            var workspaceIDs = Set<UUID>()
            var surfaceIDs = Set<UUID>()
            for workspace in AppDelegate.shared?.workspaces(boundToCloudVM: vmID) ?? [] {
                workspaceIDs.insert(workspace.id)
                surfaceIDs.formUnion(workspace.panels.keys)
                surfaceIDs.formUnion(workspace.surfaceIdToPanelId.keys.map(\.uuid))
            }
            return VMHostAuthorizationSnapshot(workspaceIDs: workspaceIDs, surfaceIDs: surfaceIDs)
        }
        guard !snapshot.workspaceIDs.isEmpty || !Self.vmHostMethodNeedsAWorkspace(request.method) else {
            return deniedVMHostRequest(request, code: "vm_host_workspace_denied", message: "No workspace is bound to this machine")
        }
        if let failure = Self.validateRelaySelectors(
            foundationParams,
            ownerWorkspaceIDs: snapshot.workspaceIDs,
            surfaceIDs: snapshot.surfaceIDs
        ) {
            return deniedVMHostRequest(request, code: failure.code.replacingOccurrences(of: "remote_relay", with: "vm_host"), message: failure.message)
        }
        let hasWorkspaceSelector = Self.containsTopLevelSelector(foundationParams, keys: Self.remoteRelayWorkspaceSelectorKeys)
        let hasSurfaceSelector = Self.containsTopLevelSelector(foundationParams, keys: Self.remoteRelaySurfaceSelectorKeys)
        if VMHostAccessPolicy.workspaceRequiredMethods.contains(request.method), !hasWorkspaceSelector {
            return deniedVMHostRequest(request, code: "vm_host_workspace_denied", message: "Method requires an explicit workspace selector")
        }
        if VMHostAccessPolicy.surfaceRequiredMethods.contains(request.method), !hasSurfaceSelector {
            return deniedVMHostRequest(request, code: "vm_host_surface_denied", message: "Method requires an explicit surface selector")
        }
        if request.method == "agent.resolve_delivery_target" {
            guard foundationParams["pid"] == nil,
                  foundationParams["pid_resolution"] == nil,
                  foundationParams["tty_name"] is String,
                  (foundationParams["tty_resolution"] as? String) == "reported_tty" else {
                return deniedVMHostRequest(request, code: "vm_host_method_denied", message: "Delivery resolution requires the reported TTY path")
            }
        }

        var sanitizedParams = request.params
        sanitizedParams.removeValue(forKey: VMHostAccessPolicy.tokenParamKey)
        return RemoteRelayAuthorizationResult(
            request: ControlRequest(id: request.id, method: request.method, params: sanitizedParams),
            errorResponse: nil
        )
    }

    private nonisolated static func vmHostMethodNeedsAWorkspace(_ method: String) -> Bool {
        VMHostAccessPolicy.workspaceRequiredMethods.contains(method)
    }

    private nonisolated func deniedVMHostRequest(_ request: ControlRequest, code: String, message: String) -> RemoteRelayAuthorizationResult {
        RemoteRelayAuthorizationResult(
            request: request,
            errorResponse: ControlResponseEncoder().error(id: request.id, code: code, message: message)
        )
    }
}
