import Foundation

extension CMUXCLI {
    /// Reduces any Pi tool result to structural metadata at the CLI trust boundary.
    ///
    /// Generated extensions project results before dispatch, but installed older
    /// versions can still send raw output. Treat both forms as untrusted so a cmux
    /// upgrade cannot persist command output before the extension is reinstalled.
    static func sanitizedPiPostToolUseFeedValue(_ value: Any) -> [String: Any] {
        var summary: [String: Any] = ["_cmux_sanitized": true]

        if value is NSNull {
            summary["kind"] = "null"
            return summary
        }
        if value is Bool {
            summary["kind"] = "boolean"
            return summary
        }
        if value is NSNumber {
            summary["kind"] = "number"
            return summary
        }
        if let text = value as? String {
            summary["kind"] = "text"
            summary["length"] = text.count
            return summary
        }
        if let array = value as? [Any] {
            summary["kind"] = "array"
            summary["count"] = array.count
            return summary
        }
        guard let dictionary = value as? [String: Any] else {
            summary["kind"] = "unknown"
            return summary
        }

        summary["_cmux_original_key_count"] = dictionary.count
        let allowedKinds = Set(["null", "text", "boolean", "number", "array", "object", "undefined"])
        var retainedKeyCount = 0
        if let kind = dictionary["kind"] as? String, allowedKinds.contains(kind) {
            summary["kind"] = kind
            retainedKeyCount += 1
        } else {
            summary["kind"] = "object"
        }
        for key in ["length", "count", "key_count", "omitted_terminal_count"] {
            if let count = dictionary[key] as? Int, count >= 0 {
                summary[key] = count
                retainedKeyCount += 1
            }
        }
        for key in ["truncated", "cmux_truncated"] {
            if let flag = dictionary[key] as? Bool {
                summary[key] = flag
                retainedKeyCount += 1
            }
        }
        if summary["kind"] as? String == "object", summary["key_count"] == nil {
            summary["key_count"] = dictionary.count
        }
        let omittedKeyCount = dictionary.count - retainedKeyCount
        if omittedKeyCount > 0 {
            summary["_cmux_omitted_key_count"] = omittedKeyCount
        }
        return summary
    }

    /// Routes a bounded Pi terminal-event batch through the ordinary Feed protocol.
    func routePiCompactedFeedEvents(
        commandArgs: [String],
        rawObject: [String: Any],
        agentPid: Int,
        fallbackWorkspaceId: String?,
        client: SocketClient?,
        socketPath: String?,
        socketPassword: String?
    ) throws -> String? {
        guard rawObject["cmux_compacted_terminal_events"] is [[String: Any]] else { return nil }

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
        return nil
    }

    private func sendPiCompactedFeedEvents(
        commandArgs: [String],
        rawObject: [String: Any],
        agentPid: Int,
        fallbackWorkspaceId: String?,
        client: SocketClient
    ) throws -> String {
        let target = try resolvePiFeedClaim(commandArgs: commandArgs, client: client)
        let request = PiCompactedFeedEventExpander(
            agentPid: agentPid,
            workspaceId: target?.workspaceId ?? fallbackWorkspaceId,
            surfaceId: target?.surfaceId,
            maximumRequestCount: client.isRelayBacked ? 2 : nil
        ).acknowledgedBatchRequest(from: rawObject)
        guard let request else { throw piFeedAcknowledgmentError() }

        let response = try client.send(
            command: request.line,
            responseTimeout: 4
        )
        let acknowledgedTarget = try validatePiFeedAcknowledgment(
            response,
            expectedItemCount: request.eventCount
        )
        return piHookResolvedTargetOutput(acknowledgedTarget)
    }

    /// Preserves exact Pi Feed claims for authoritative acceptance by the app.
    ///
    /// UUID claims need no preliminary socket request. Legacy numeric and handle
    /// references still resolve here because the Feed protocol carries UUIDs.
    func resolvePiFeedClaim(
        commandArgs: [String],
        client: SocketClient
    ) throws -> (workspaceId: String?, surfaceId: String)? {
        let rawSurface = optionValue(commandArgs, name: "--surface")
            ?? ProcessInfo.processInfo.environment["CMUX_SURFACE_ID"]
        guard let rawSurface else { return nil }
        let surface = rawSurface.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !surface.isEmpty else { return nil }

        let rawWorkspace = optionValue(commandArgs, name: "--workspace")
            ?? ProcessInfo.processInfo.environment["CMUX_WORKSPACE_ID"]
        let workspace = normalizedHandleValue(rawWorkspace)
        if isUUID(surface), workspace == nil || workspace.map(isUUID) == true {
            return (workspace, surface)
        }

        return try resolveStrictPiHookTarget(commandArgs: commandArgs, client: client).map {
            ($0.workspaceId, $0.surfaceId)
        }
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
        let trimmedWorkspace = normalizedHandleValue(rawWorkspace)
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
                   let workspaceUUID = UUID(uuidString: workspaceId),
                   let returnedSurfaceId = normalizedHandleValue(payload["surface_id"] as? String),
                   let returnedSurfaceUUID = UUID(uuidString: returnedSurfaceId) {
                    // The relay can rewrite a restored surface alias before the
                    // app resolves it, so the app's returned UUID is authoritative.
                    return (workspaceUUID.uuidString, returnedSurfaceUUID.uuidString)
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
    ) throws -> (workspaceId: String, surfaceId: String)? {
        let decodedResponse: Any
        do {
            decodedResponse = try JSONSerialization.jsonObject(with: Data(response.utf8))
        } catch {
            throw piFeedAcknowledgmentError()
        }
        guard let responseObject = decodedResponse as? [String: Any] else {
            throw piFeedAcknowledgmentError()
        }
        if responseObject["ok"] as? Bool == false,
           let error = responseObject["error"] as? [String: Any],
           error["code"] as? String == "not_found" {
            throw CLIError(
                message: String(
                    localized: "agent.deliveryTarget.error.notFound",
                    defaultValue: "No live delivery target"
                ),
                exitCode: Self.piHookSurfaceUnavailableExitCode,
                v2Code: "not_found"
            )
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
                return piFeedAcknowledgedTarget(result)
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
        return piFeedAcknowledgedTarget(result)
    }

    private func piFeedAcknowledgedTarget(
        _ result: [String: Any]
    ) -> (workspaceId: String, surfaceId: String)? {
        guard let workspaceId = normalizedHandleValue(result["workspace_id"] as? String),
              isUUID(workspaceId),
              let surfaceId = normalizedHandleValue(result["surface_id"] as? String),
              isUUID(surfaceId) else {
            return nil
        }
        return (workspaceId, surfaceId)
    }

    private func piFeedAcknowledgmentError() -> CLIError {
        CLIError(message: String(
            localized: "cli.hooks.pi.error.feedIngestionNotAcknowledged",
            defaultValue: "cmux did not receive acknowledgment for Pi feed ingestion"
        ))
    }
}
