import Foundation
import os

/// Sends one warm RPC per session and records exactly the sessions Quit must account for.
actor AcpmuxLaunchWarm {
    private var requested = Set<String>()
    var hasRequests: Bool { !requested.isEmpty }

    private let call: @Sendable (String, [String: any Sendable]) async throws -> Bool

    init() {
        call = { socket, params in
            let result = try await AcpmuxStatusClient.call(socketPath: socket, method: "_acpmux/warm", params: params,
                                                          deadline: .seconds(60), requiredFeature: "launchWarm")
            guard let failed = result["failed"] as? [[String: Any]] else {
                throw AcpmuxStatusClient.Failure.rpc("Missing launch warm result")
            }
            return failed.isEmpty
        }
    }

    init(call: @escaping @Sendable (String, [String: any Sendable]) async throws -> Bool) { self.call = call }

    func warm(_ sessions: [String], socket: String) async throws {
        var failed: [String] = []
        for session in sessions {
            try Task.checkCancellation()
            // Record before dispatch: a cancelled/lost reply can still have started this chat.
            requested.insert(session)
            do {
                let succeeded = try await call(socket, ["sessionIds": [session], "limit": 1])
                if !succeeded { failed.append(session) }
            } catch {
                // Capability refusal happens before dispatch, so it cannot have started a chat.
                if case .unsupportedFeature = error as? AcpmuxStatusClient.Failure { requested.remove(session) }
                try Task.checkCancellation()
                failed.append(session)
                Logger(subsystem: "com.cmuxterm.app.next", category: "agent.launch")
                    .error("launch warm failed: \(String(describing: error), privacy: .public)")
            }
        }
        if !failed.isEmpty { throw AgentPaneWarmFailure(sessionIds: failed) }
    }

    /// Quit retries only unresolved targets; other sessions on a shared daemon are never ended.
    func end(environment: AcpmuxEnvironment, waitForShutdown: Bool = false) async -> AcpmuxQuit.EndResult {
        await end { await AcpmuxLaunchCleanup(environment: environment).end($0, waitForShutdown: waitForShutdown) }
    }

    func end(ending: @Sendable ([String]) async -> Set<String>) async -> AcpmuxQuit.EndResult {
        guard !requested.isEmpty else { return .noDaemon }
        let ended = await ending(requested.sorted())
        requested.subtract(ended)
        return requested.isEmpty ? .ended : .agentsStillRunning(requested.sorted())
    }
}
