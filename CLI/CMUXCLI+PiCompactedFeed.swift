import Foundation

extension CMUXCLI {
    /// Routes a bounded Pi terminal-event batch through the ordinary Feed protocol.
    func routePiCompactedFeedEvents(
        commandArgs: [String],
        rawObject: [String: Any],
        agentPid: Int,
        fallbackWorkspaceId: String?,
        client: SocketClient?,
        socketPath: String?,
        socketPassword: String?
    ) throws -> Bool {
        guard rawObject["cmux_compacted_terminal_events"] is [[String: Any]] else { return false }

        if let client {
            return try sendPiCompactedFeedEvents(
                commandArgs: commandArgs,
                rawObject: rawObject,
                agentPid: agentPid,
                fallbackWorkspaceId: fallbackWorkspaceId,
                client: client
            )
        } else if let socketPath {
            let batchClient = SocketClient(path: socketPath)
            defer { batchClient.close() }
            try batchClient.connect()
            try authenticateClientIfNeeded(
                batchClient,
                explicitPassword: socketPassword,
                socketPath: socketPath,
                responseTimeout: 1
            )
            return try sendPiCompactedFeedEvents(
                commandArgs: commandArgs,
                rawObject: rawObject,
                agentPid: agentPid,
                fallbackWorkspaceId: fallbackWorkspaceId,
                client: batchClient
            )
        }
        return false
    }

    private func sendPiCompactedFeedEvents(
        commandArgs: [String],
        rawObject: [String: Any],
        agentPid: Int,
        fallbackWorkspaceId: String?,
        client: SocketClient
    ) throws -> Bool {
        let target = try resolveStrictPiHookTarget(commandArgs: commandArgs, client: client)
        let request = PiCompactedFeedEventExpander(
            agentPid: agentPid,
            workspaceId: target?.workspaceId ?? fallbackWorkspaceId,
            surfaceId: target?.surfaceId,
            maximumRequestCount: client.isRelayBacked ? 2 : nil
        ).acknowledgedBatchRequest(from: rawObject)
        guard let request else { return false }

        let response = try client.send(
            command: request.line,
            responseTimeout: 4
        )
        try validatePiFeedAcknowledgment(response, expectedItemCount: request.eventCount)
        return true
    }

    /// Resolves and validates a Pi extension's explicit or inherited surface without pane fallback.
    func resolveStrictPiHookTarget(
        commandArgs: [String],
        client: SocketClient
    ) throws -> (workspaceId: String, surfaceId: String)? {
        let rawSurface = optionValue(commandArgs, name: "--surface")
            ?? ProcessInfo.processInfo.environment["CMUX_SURFACE_ID"]
        guard let rawSurface, !rawSurface.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        let surface = rawSurface.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isUUID(surface)
            || Int(surface) != nil
            || piHookHandleRef(surface, kind: "surface")
        else {
            throw piHookSurfaceNotFoundError(rawSurface)
        }
        let rawWorkspace = optionValue(commandArgs, name: "--workspace")
            ?? ProcessInfo.processInfo.environment["CMUX_WORKSPACE_ID"]
        let trimmedWorkspace = rawWorkspace?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let workspace = trimmedWorkspace {
            guard isUUID(workspace)
                || Int(workspace) != nil
                || piHookHandleRef(workspace, kind: "workspace")
            else {
                throw piHookSurfaceNotFoundError(workspace)
            }
        }
        let resolvedWorkspaceId: String?
        if let workspace = trimmedWorkspace, isUUID(workspace) {
            // Exact workspace IDs are only preferred hints for exact surfaces;
            // the global live-surface resolver below remains authoritative.
            resolvedWorkspaceId = workspace
        } else {
            do {
                resolvedWorkspaceId = try resolveWorkspaceId(trimmedWorkspace, client: client)
            } catch let error as CLIError where error.v2Code == "not_found" {
                if trimmedWorkspace != nil {
                    // A supplied index/ref failed to resolve and cannot be
                    // discarded without violating the caller's explicit scope.
                    throw CLIError(
                        message: error.message,
                        exitCode: Self.piHookSurfaceUnavailableExitCode,
                        v2Code: error.v2Code
                    )
                }
                resolvedWorkspaceId = nil
            }
        }
        if isUUID(surface) {
            var params: [String: Any] = ["surface_id": surface]
            if let resolvedWorkspaceId, isUUID(resolvedWorkspaceId) {
                params["workspace_id"] = resolvedWorkspaceId
            }
            do {
                let payload = try client.sendV2(
                    method: "agent.resolve_delivery_target",
                    params: params,
                    responseTimeout: 2
                )
                if (payload["source"] as? String) == "surface",
                   let workspaceId = normalizedHandleValue(payload["workspace_id"] as? String),
                   isUUID(workspaceId),
                   let returnedSurfaceId = normalizedHandleValue(payload["surface_id"] as? String),
                   UUID(uuidString: returnedSurfaceId) == UUID(uuidString: surface) {
                    return (workspaceId, surface)
                }
                throw piHookSurfaceNotFoundError(rawSurface)
            } catch let error as CLIError where error.v2Code == "method_not_found"
                    || error.v2Code == "unrecognized_method" {
                // Older apps lack the surface-scoped resolver. Preserve the
                // legacy workspace-local lookup without making supported
                // apps snapshot every surface for each Pi tool event.
            } catch let error as CLIError where error.v2Code == "not_found" {
                throw piHookSurfaceNotFoundError(rawSurface)
            }
        }

        if let workspaceId = resolvedWorkspaceId {
            let listed = try client.sendV2(method: "surface.list", params: ["workspace_id": workspaceId])
            let surfaces = listed["surfaces"] as? [[String: Any]] ?? []
            let surfaceId: String? = if isUUID(surface) {
                surfaces.first(where: { ($0["id"] as? String) == surface })?["id"] as? String
            } else if let index = Int(surface) {
                surfaces.first(where: { piHookInteger($0["index"]) == index })?["id"] as? String
            } else {
                surfaces.first(where: { ($0["ref"] as? String) == surface })?["id"] as? String
            }
            if let surfaceId {
                return (workspaceId, surfaceId)
            }
        }
        throw piHookSurfaceNotFoundError(rawSurface)
    }

    private func piHookHandleRef(_ raw: String, kind: String) -> Bool {
        let pieces = raw.split(separator: ":", omittingEmptySubsequences: false)
        return pieces.count == 2
            && pieces[0].lowercased() == kind
            && Int(pieces[1]) != nil
    }

    private func piHookInteger(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) }
        return nil
    }

    /// Builds the localized failure shared by strict Pi lifecycle and feed routing.
    func piHookSurfaceNotFoundError(_ rawSurface: String) -> CLIError {
        CLIError(message: String.localizedStringWithFormat(
            String(
                localized: "cli.claude-hook.error.surfaceNotFound",
                defaultValue: "Surface not found: %@"
            ),
            rawSurface
        ), exitCode: Self.piHookSurfaceUnavailableExitCode, v2Code: "not_found")
    }

    /// Stable process status consumed by the generated extension without parsing localized stderr.
    static let piHookSurfaceUnavailableExitCode: Int32 = 69

    func piHookResolvedTargetOutput(
        _ target: (workspaceId: String, surfaceId: String)?
    ) -> String {
        guard let target,
              let data = try? JSONSerialization.data(withJSONObject: [
                  "workspace_id": target.workspaceId,
                  "surface_id": target.surfaceId,
              ]),
              let output = String(data: data, encoding: .utf8)
        else { return "{}" }
        return output
    }

    /// Rejects a Pi feed response unless the server confirms ingestion.
    func validatePiFeedAcknowledgment(
        _ response: String,
        expectedItemCount: Int? = nil
    ) throws {
        let decodedResponse: Any
        do {
            decodedResponse = try JSONSerialization.jsonObject(with: Data(response.utf8))
        } catch {
            throw piFeedAcknowledgmentError()
        }
        guard let responseObject = decodedResponse as? [String: Any] else {
            throw piFeedAcknowledgmentError()
        }
        guard responseObject["ok"] as? Bool == true,
              let result = responseObject["result"] as? [String: Any],
              result["status"] as? String == "acknowledged"
        else {
            throw piFeedAcknowledgmentError()
        }
        if let expectedItemCount {
            if expectedItemCount == 1,
               let itemId = result["item_id"] as? String,
               UUID(uuidString: itemId) != nil {
                return
            }
            guard expectedItemCount > 0,
                  let itemIds = result["item_ids"] as? [String],
                  itemIds.count == expectedItemCount,
                  itemIds.allSatisfy({ UUID(uuidString: $0) != nil })
            else {
                throw piFeedAcknowledgmentError()
            }
        } else {
            guard let itemId = result["item_id"] as? String,
                  UUID(uuidString: itemId) != nil
            else {
                throw piFeedAcknowledgmentError()
            }
        }
    }

    private func piFeedAcknowledgmentError() -> CLIError {
        CLIError(message: String(
            localized: "cli.hooks.pi.error.feedIngestionNotAcknowledged",
            defaultValue: "cmux did not receive acknowledgment for Pi feed ingestion"
        ))
    }
}
