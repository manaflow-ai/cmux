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
        let requestLines = PiCompactedFeedEventExpander(
            agentPid: agentPid,
            workspaceId: fallbackWorkspaceId
        ).requestLines(from: rawObject)
        guard !requestLines.isEmpty else { return false }

        if let client {
            try validateExplicitPiHookTarget(commandArgs: commandArgs, client: client)
            for line in requestLines {
                try sendAcknowledgedPiFeed(line, client: client)
            }
        } else if let socketPath {
            let batchClient = SocketClient(path: socketPath)
            defer { batchClient.close() }
            try batchClient.connectWithoutRetry(responseTimeout: 0.05)
            try authenticateClientIfNeeded(
                batchClient,
                explicitPassword: socketPassword,
                socketPath: socketPath,
                responseTimeout: 0.05
            )
            try validateExplicitPiHookTarget(commandArgs: commandArgs, client: batchClient)
            for line in requestLines {
                try sendAcknowledgedPiFeed(line, client: batchClient)
            }
        }
        return true
    }

    /// Validates a Pi extension's explicit surface without falling back to another pane.
    func validateExplicitPiHookTarget(commandArgs: [String], client: SocketClient) throws {
        guard let rawSurface = optionValue(commandArgs, name: "--surface") else { return }
        let rawWorkspace = optionValue(commandArgs, name: "--workspace")
            ?? ProcessInfo.processInfo.environment["CMUX_WORKSPACE_ID"]
        let workspaceId: String
        do {
            workspaceId = try resolveWorkspaceId(rawWorkspace, client: client)
        } catch {
            throw piHookSurfaceNotFoundError(rawSurface)
        }
        let surfaceId: String
        do {
            surfaceId = try resolveSurfaceId(rawSurface, workspaceId: workspaceId, client: client)
        } catch {
            throw piHookSurfaceNotFoundError(rawSurface)
        }
        let listed: [String: Any]
        do {
            listed = try client.sendV2(method: "surface.list", params: ["workspace_id": workspaceId])
        } catch {
            throw piHookSurfaceNotFoundError(rawSurface)
        }
        let surfaces = listed["surfaces"] as? [[String: Any]] ?? []
        guard surfaces.contains(where: {
            ($0["id"] as? String) == surfaceId || ($0["ref"] as? String) == surfaceId
        }) else {
            throw piHookSurfaceNotFoundError(rawSurface)
        }
    }

    /// Builds the localized failure shared by strict Pi lifecycle and feed routing.
    func piHookSurfaceNotFoundError(_ rawSurface: String) -> CLIError {
        CLIError(message: String.localizedStringWithFormat(
            String(
                localized: "cli.claude-hook.error.surfaceNotFound",
                defaultValue: "Surface not found: %@"
            ),
            rawSurface
        ))
    }

    private func sendAcknowledgedPiFeed(_ line: String, client: SocketClient) throws {
        let response = try client.send(command: line, responseTimeout: 4)
        try validatePiFeedAcknowledgment(response)
    }

    /// Rejects a Pi feed response unless the server confirms ingestion.
    func validatePiFeedAcknowledgment(_ response: String) throws {
        let decodedResponse: Any
        do {
            decodedResponse = try JSONSerialization.jsonObject(with: Data(response.utf8))
        } catch {
            throw piFeedAcknowledgmentError()
        }
        guard let responseObject = decodedResponse as? [String: Any] else {
            throw piFeedAcknowledgmentError()
        }
        guard responseObject["ok"] as? Bool == true else {
            throw piFeedAcknowledgmentError()
        }
    }

    private func piFeedAcknowledgmentError() -> CLIError {
        CLIError(message: String(
            localized: "cli.hooks.pi.error.feedIngestionNotAcknowledged",
            defaultValue: "cmux did not receive acknowledgment for Pi feed ingestion"
        ))
    }
}
