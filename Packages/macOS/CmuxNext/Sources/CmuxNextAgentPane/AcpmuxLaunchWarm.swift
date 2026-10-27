import Foundation
import os

/// Sends one warm RPC per session. Retries preserve both the daemon launch and stop generation.
actor AcpmuxLaunchWarm {
    nonisolated struct Fence: Sendable, Equatable {
        let epoch: String
        let stops: UInt64

        init(epoch: String, stops: UInt64) { self.epoch = epoch; self.stops = stops }

        init?(result: [String: Any]) {
            guard let epoch = result["daemonEpoch"] as? String,
                  let failures = result["failed"] as? [[String: Any]],
                  let retry = failures.first(where: { $0["retryable"] as? Bool == true }),
                  let stops = retry["stops"] as? NSNumber else { return nil }
            self.init(epoch: epoch, stops: stops.uint64Value)
        }
    }

    private var requested = Set<String>()
    var hasRequests: Bool { !requested.isEmpty }

    private var fences: [String: Fence] = [:]
    private let call: @Sendable (String, [String: any Sendable]) async throws -> Fence?

    init() {
        call = { socket, params in
            let result = try await AcpmuxStatusClient.call(socketPath: socket, method: "_acpmux/warm", params: params,
                                                          deadline: .seconds(60), requiredFeature: "launchWarm")
            return Fence(result: result)
        }
    }

    init(call: @escaping @Sendable (String, [String: any Sendable]) async throws -> Fence?) { self.call = call }

    func warm(_ sessions: [String], socket: String) async throws {
        var failed: [String] = []
        for session in sessions {
            try Task.checkCancellation()
            var params: [String: any Sendable] = ["sessionIds": [session], "limit": 1]
            if let fence = fences[session] {
                params["expectedStopCounts"] = [session: fence.stops]
                params["expectedDaemonEpoch"] = fence.epoch
            }
            // Record before dispatch: a cancelled/lost reply can still have started this chat.
            requested.insert(session)
            do {
                fences[session] = try await call(socket, params)
                if fences[session] != nil { failed.append(session) }
            } catch {
                try Task.checkCancellation()
                // A lost reply may have started the agent. Without a prior fence, retrying could
                // undo a person's subsequent Stop. Endpoint/startup failures are retried upstream.
                if fences[session] != nil { failed.append(session) }
                else {
                    Logger(subsystem: "com.cmuxterm.app.next", category: "agent.launch")
                        .error("launch warm reply unavailable; restoration unknown, no unfenced retry: \(String(describing: error), privacy: .public)")
                }
            }
        }
        if !failed.isEmpty { throw AgentPaneWarmFailure(sessionIds: failed) }
    }

    /// Quit retries only unresolved targets; other sessions on a shared daemon are never ended.
    func end(environment: AcpmuxEnvironment) async -> AcpmuxQuit.EndResult {
        await end { await AcpmuxLaunchCleanup(environment: environment).end($0) }
    }

    func end(ending: @Sendable ([String]) async -> Set<String>) async -> AcpmuxQuit.EndResult {
        guard !requested.isEmpty else { return .noDaemon }
        let ended = await ending(requested.sorted())
        requested.subtract(ended)
        return requested.isEmpty ? .ended : .agentsStillRunning(requested.sorted())
    }
}
