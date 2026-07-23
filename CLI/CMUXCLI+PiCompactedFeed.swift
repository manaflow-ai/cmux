import Foundation

extension CMUXCLI {
    /// Routes a bounded Pi terminal-event batch through the ordinary Feed protocol.
    func routePiCompactedFeedEvents(
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
            for line in requestLines {
                try sendAcknowledgedPiFeed(line, client: batchClient)
            }
        }
        return true
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
