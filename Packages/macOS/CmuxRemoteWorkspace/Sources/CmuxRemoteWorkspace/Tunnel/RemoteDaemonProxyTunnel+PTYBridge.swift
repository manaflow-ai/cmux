internal import Foundation

extension RemoteDaemonProxyTunnel {
    /// Starts a single-use loopback PTY bridge server for a terminal attach
    /// and returns its endpoint.
    public func startPTYBridge(
        sessionID: String,
        attachmentID: String,
        command: String?,
        requireExisting: Bool
    ) throws -> RemotePTYBridgeServer.Endpoint {
        try queue.sync {
            guard let rpcClient, !isStopped else {
                throw NSError(domain: "cmux.remote.pty", code: 33, userInfo: [
                    NSLocalizedDescriptionKey: "remote daemon tunnel is not ready",
                ])
            }
            let bridgeID = UUID()
            let server = RemotePTYBridgeServer(
                rpcClient: rpcClient,
                sessionID: sessionID,
                attachmentID: attachmentID,
                command: command,
                requireExisting: requireExisting,
                strings: ptyBridgeStrings,
                clock: clock
            ) { [weak self] in
                guard let self else { return }
                self.queue.async {
                    self.ptyBridgeServers.removeValue(forKey: bridgeID)
                }
            }
            let endpoint = try server.start()
            ptyBridgeServers[bridgeID] = RemotePTYBridgeServerRecord(
                server: server,
                sessionID: sessionID,
                attachmentID: attachmentID
            )
            return endpoint
        }
    }

    /// Invalidates every live local bridge for `sessionID` and returns the
    /// number of affected endpoints for each attachment identifier.
    ///
    /// - Parameter sessionID: The persistent PTY session identifier.
    /// - Returns: The number of invalidated endpoints for each attachment identifier.
    public func invalidatePTYBridges(sessionID: String) -> [String: Int] {
        queue.sync {
            let invalidated = ptyBridgeServers.filter { $0.value.sessionID == sessionID }
            for bridgeID in invalidated.keys {
                ptyBridgeServers.removeValue(forKey: bridgeID)
            }

            var attachmentCounts: [String: Int] = [:]
            for record in invalidated.values {
                attachmentCounts[record.attachmentID, default: 0] += 1
                record.server.stop()
            }
            return attachmentCounts
        }
    }
}
