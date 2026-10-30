import Foundation
import Testing
@testable import CmuxNextAgentPane

struct AcpmuxLaunchWarmTests {
    @Test func failedAndLostRepliesAreReportedOnceWhileSiblingsContinue() async {
        let peer = AcpmuxLaunchWarmPeer([.failed, .lost, .success])
        let warm = AcpmuxLaunchWarm { _, params in try await peer.reply(params) }
        do {
            try await warm.warm(["failed", "lost", "ready"], socket: "unused")
            Issue.record("launch must report the failed sessions")
        } catch let error as AgentPaneWarmFailure {
            #expect(error.sessionIds == ["failed", "lost"])
        } catch { Issue.record("unexpected failure: \(error)") }
        #expect(await peer.requests == [["failed"], ["lost"], ["ready"]])
    }

    @Test func endStopsOnlyRequestedChatsAndRetriesOnlyUnresolvedTargets() async throws {
        let warm = AcpmuxLaunchWarm { _, _ in true }
        try await warm.warm(["mine", "mine-too"], socket: "unused")
        let first = await warm.end { sessions in
            #expect(sessions == ["mine", "mine-too"])
            return ["mine"]
        }
        #expect(first == .agentsStillRunning(["mine-too"]))
        let second = await warm.end { sessions in
            #expect(sessions == ["mine-too"])
            return Set(sessions)
        }
        #expect(second == .ended)
        let completed = await warm.end { _ in Issue.record("completed cleanup sent another request"); return [] }
        #expect(completed == .noDaemon)
    }

    @Test func aLostWarmReplyStillRecordsTheExactChatForEndSessions() async {
        let warm = AcpmuxLaunchWarm { _, _ in throw AcpmuxStatusClient.Failure.closed }
        await #expect(throws: AgentPaneWarmFailure.self) { try await warm.warm(["mine"], socket: "unused") }
        let ended = await warm.end { sessions in
            #expect(sessions == ["mine"])
            return Set(sessions)
        }
        #expect(ended == .ended)
    }

    @Test func unsupportedDaemonReceivesNoCleanupRequest() async {
        let warm = AcpmuxLaunchWarm { _, _ in throw AcpmuxStatusClient.Failure.unsupportedFeature("launchWarm") }
        await #expect(throws: AgentPaneWarmFailure.self) { try await warm.warm(["mine"], socket: "unused") }
        #expect(await warm.hasRequests == false)
        let ended = await warm.end { _ in Issue.record("unsupported warm was never sent"); return [] }
        #expect(ended == .noDaemon)
    }

    @Test func cancellationRetainsEarlierAndInFlightChatsButNotQueuedOnes() async throws {
        let (starts, started) = AsyncStream<Void>.makeStream()
        let warm = AcpmuxLaunchWarm { _, params in
            if (params["sessionIds"] as? [String]) == ["in-flight"] {
                started.yield(())
                let (stream, hold) = AsyncStream<Void>.makeStream()
                defer { hold.finish() }
                for await _ in stream {}
                try Task.checkCancellation()
            }
            return true
        }
        let task = Task { try await warm.warm(["completed", "in-flight", "queued"], socket: "unused") }
        defer { task.cancel() }
        try await withAgentPaneDeadline(.seconds(5), label: "sibling warm begins") {
            for await _ in starts { return }
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        let ended = await warm.end { sessions in
            #expect(sessions == ["completed", "in-flight"])
            return Set(sessions)
        }
        #expect(ended == .ended)
    }
}
