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
            _ = try resolveExplicitPiHookTarget(commandArgs: commandArgs, client: client)
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
            _ = try resolveExplicitPiHookTarget(commandArgs: commandArgs, client: batchClient)
            for line in requestLines {
                try sendAcknowledgedPiFeed(line, client: batchClient)
            }
        }
        return true
    }

    /// Resolves a Pi extension's explicit surface without falling back to another pane.
    func resolveExplicitPiHookTarget(
        commandArgs: [String],
        client: SocketClient
    ) throws -> (workspaceId: String, surfaceId: String)? {
        guard let rawSurface = optionValue(commandArgs, name: "--surface") else { return nil }
        let surface = rawSurface.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isUUID(surface)
            || Int(surface) != nil
            || piHookHandleRef(surface, kind: "surface")
        else {
            throw piHookSurfaceNotFoundError(rawSurface)
        }
        let rawWorkspace = optionValue(commandArgs, name: "--workspace")
            ?? ProcessInfo.processInfo.environment["CMUX_WORKSPACE_ID"]
        if let rawWorkspace {
            let workspace = rawWorkspace.trimmingCharacters(in: .whitespacesAndNewlines)
            guard isUUID(workspace)
                || Int(workspace) != nil
                || piHookHandleRef(workspace, kind: "workspace")
            else {
                throw piHookSurfaceNotFoundError(rawSurface)
            }
        }
        let workspaceId = try resolveWorkspaceId(rawWorkspace, client: client)
        let listed: [String: Any]
        do {
            listed = try client.sendV2(method: "surface.list", params: ["workspace_id": workspaceId])
        } catch let error as CLIError where error.v2Code == "not_found" {
            throw piHookSurfaceNotFoundError(rawSurface)
        }
        let surfaces = listed["surfaces"] as? [[String: Any]] ?? []
        let surfaceId: String? = if isUUID(surface) {
            surfaces.first(where: { ($0["id"] as? String) == surface })?["id"] as? String
        } else if let index = Int(surface) {
            surfaces.first(where: { piHookInteger($0["index"]) == index })?["id"] as? String
        } else {
            surfaces.first(where: { ($0["ref"] as? String) == surface })?["id"] as? String
        }
        guard let surfaceId else {
            throw piHookSurfaceNotFoundError(rawSurface)
        }
        return (workspaceId, surfaceId)
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
