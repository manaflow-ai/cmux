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

        for line in requestLines {
            if let client {
                _ = try? client.sendOneWay(command: line, writeTimeout: 0.05)
            } else if let socketPath {
                sendBestEffortFeedTelemetry(
                    socketPath: socketPath,
                    line: line,
                    socketPassword: socketPassword
                )
            }
        }
        return true
    }
}
