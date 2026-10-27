import Foundation

/// Sends one warm RPC per session, retaining failed requests' stop generations across retries.
/// A new daemon token invalidates those process-local generations; successes and skips drop them.
actor AcpmuxLaunchWarm {
    private var stops: [String: UInt64] = [:]
    private var epoch: String?

    func warm(_ sessions: [String], socket: String, epoch: String) async throws {
        if self.epoch != epoch { stops.removeAll(); self.epoch = epoch }
        var failed: [String] = []
        for session in sessions {
            try Task.checkCancellation()
            var params: [String: any Sendable] = ["sessionIds": [session], "limit": 1]
            if let count = stops[session] { params["expectedStopCounts"] = [session: count] }
            do {
                let result = try await AcpmuxStatusClient.call(socketPath: socket, method: "_acpmux/warm", params: params, deadline: .seconds(60))
                if let failures = result["failed"] as? [[String: Any]],
                   let retry = failures.first(where: { $0["retryable"] as? Bool == true }) {
                    failed.append(session)
                    if self.epoch == epoch { stops[session] = (retry["stops"] as? NSNumber)?.uint64Value }
                } else if self.epoch == epoch { stops[session] = nil }
            } catch {
                try Task.checkCancellation()
                failed.append(session)
            }
        }
        if !failed.isEmpty { throw AgentPaneWarmFailure(sessionIds: failed) }
    }
}
