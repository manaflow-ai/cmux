import Foundation

/// End Sessions for restored tabs on a shared daemon. Its process and unrelated chats stay up.
nonisolated struct AcpmuxLaunchCleanup {
    let environment: AcpmuxEnvironment

    @concurrent func end(_ sessions: [String]) async -> Set<String> {
        guard !environment.isAttached else { return Set(sessions) }
        do {
            return try await withAgentPaneDeadline(.seconds(10), label: "end restored chats") {
                try await self.stop(sessions)
            }
        } catch {
            // A daemon that already exited can be proven ended without a socket. An unreachable
            // running daemon is unresolved, so Quit offers Retry instead of claiming success.
            let facts = AcpmuxQuitProof.read(home: environment.home)
            guard facts.daemon == .free else { return [] }
            return Set(sessions).subtracting(facts.liveHostSessions + facts.unknownHostSessions)
        }
    }

    private func stop(_ sessions: [String]) async throws -> Set<String> {
        let status = try await AcpmuxStatusClient.status(socketPath: environment.socketPath)
        guard status.serves(home: environment.home) else { throw AcpmuxStatusClient.Failure.otherHome(status.home ?? "") }
        let listing = try await AcpmuxStatusClient.sessions(socketPath: environment.socketPath, deadline: .seconds(2)).value
        let known = Set((listing["sessions"] as? [[String: Any]] ?? []).compactMap { $0["sessionId"] as? String })
        let stopped = await withTaskGroup(of: String?.self) { group in
            var next = 0
            var ended = Set<String>()
            func add(_ index: Int) {
                let session = sessions[index]
                group.addTask {
                    do {
                        try Task.checkCancellation()
                        if known.contains(session) { try await environment.stopSession(id: session) }
                        return session
                    } catch { return nil }
                }
            }
            while next < min(4, sessions.count) { add(next); next += 1 }
            for await session in group {
                if let session { ended.insert(session) }
                if Task.isCancelled { group.cancelAll() }
                else if next < sessions.count { add(next); next += 1 }
            }
            return ended
        }
        // An acknowledged stop still has to have ended its hosted process. Probe once for the
        // whole batch, not once per tab; Retry keeps only the unresolved targets.
        let facts = AcpmuxQuitProof.read(home: environment.home)
        return stopped.subtracting(facts.liveHostSessions + facts.unknownHostSessions)
    }
}
