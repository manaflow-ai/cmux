extension CMUXCLI {
    /// Routes a bounded Pi terminal-event batch through the ordinary Feed protocol.
    func routePiCompactedFeedEvents(
        rawObject: [String: Any],
        agentPid: Int,
        fallbackWorkspaceId: String?,
        client: SocketClient?,
        socketPath: String?,
        socketPassword: String?
    ) -> Bool {
        let requestLines = PiCompactedFeedEventExpander(
            agentPid: agentPid,
            workspaceId: fallbackWorkspaceId
        ).requestLines(from: rawObject)
        guard !requestLines.isEmpty else { return false }

        if let client {
            for line in requestLines {
                _ = try? client.sendOneWay(command: line, writeTimeout: 0.05)
            }
        } else if let socketPath {
            let batchClient = SocketClient(path: socketPath)
            defer { batchClient.close() }
            do {
                try batchClient.connectWithoutRetry(responseTimeout: 0.05)
                try authenticateClientIfNeeded(
                    batchClient,
                    explicitPassword: socketPassword,
                    socketPath: socketPath,
                    responseTimeout: 0.05
                )
                for line in requestLines {
                    try batchClient.sendOneWay(command: line, writeTimeout: 0.05)
                }
            } catch {
                return true
            }
        }
        return true
    }
}
