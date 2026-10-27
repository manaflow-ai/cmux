import Foundation
import Testing
@testable import CmuxNextAgentPane

struct AcpmuxLaunchWarmTests {
    @Test func anAmbiguousFirstReplyIsNeverRetriedWithoutAStopFence() async throws {
        let peer = AcpmuxLaunchWarmPeer([1])
        let warm = AcpmuxLaunchWarm { _, params in try await peer.reply(params) }
        // The daemon accepted the call, but its reply was lost. A person may Stop at any time.
        try await warm.warm(["chat"], socket: "unused")
        #expect(await peer.requests.count == 1)
    }

    @Test func retriesKeepTheOriginalFenceThroughLostRepliesAndStopAfterAnEpochMismatch() async throws {
        let fence = AcpmuxLaunchWarm.Fence(epoch: "123:456", stops: 7)
        let peer = AcpmuxLaunchWarmPeer([0, 1, 2], retryFence: fence)
        let warm = AcpmuxLaunchWarm { _, params in try await peer.reply(params) }
        for _ in 0..<2 {
            await #expect(throws: AgentPaneWarmFailure.self) { try await warm.warm(["chat"], socket: "unused") }
        }
        // A new daemon returns an intentional skip for the old epoch, with no retryable failure.
        try await warm.warm(["chat"], socket: "unused")
        let requests = await peer.requests
        #expect(requests.count == 3)
        #expect(requests[0].0 == nil)
        #expect(requests.dropFirst().allSatisfy { $0.0 == fence.epoch && $0.1 == fence.stops })
    }

    @Test func onlyAReplyWithBothLaunchAndStopGenerationAllowsRetry() {
        let failure: [String: Any] = ["sessionId": "chat", "retryable": true, "stops": 2]
        #expect(AcpmuxLaunchWarm.Fence(result: ["failed": [failure]]) == nil)
        #expect(AcpmuxLaunchWarm.Fence(result: ["daemonEpoch": "1:2", "failed": [failure]]) == .init(epoch: "1:2", stops: 2))
        #expect(AcpmuxLaunchWarm.Fence(result: ["daemonEpoch": "1:2", "failed": []]) == nil)
    }

    @Test func endStopsOnlyRequestedChatsAndRetriesOnlyUnresolvedTargets() async throws {
        let warm = AcpmuxLaunchWarm { _, _ in nil }
        try await warm.warm(["mine", "mine-too"], socket: "unused")
        let first = await warm.end { sessions in
            #expect(sessions == ["mine", "mine-too"])
            return ["mine"]
        }
        #expect(first == .agentsStillRunning(["mine-too"]))
        let second = await warm.end { sessions in Set(sessions) }
        #expect(second == .ended)
        #expect(await warm.end { _ in Issue.record("completed cleanup sent another request"); return [] } == .noDaemon)
    }

    @Test func aLostWarmReplyStillRecordsTheExactChatForEndSessions() async throws {
        let warm = AcpmuxLaunchWarm { _, _ in throw AcpmuxStatusClient.Failure.closed }
        try await warm.warm(["mine"], socket: "unused")
        let ended = await warm.end { sessions in Set(sessions) }
        #expect(ended == .ended)
    }

    @Test func cancellationRetainsEarlierAndInFlightChatsButNotQueuedOnes() async throws {
        let (starts, started) = AsyncStream<Void>.makeStream()
        let warm = AcpmuxLaunchWarm { _, params in
            if (params["sessionIds"] as? [String]) == ["in-flight"] {
                started.yield(())
                try await Task.sleep(for: .seconds(60))
            }
            return nil
        }
        let task = Task { try await warm.warm(["completed", "in-flight", "queued"], socket: "unused") }
        defer { task.cancel() }
        try await withAgentPaneDeadline(.seconds(5), label: "sibling warm begins") {
            for await _ in starts { return }
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        let ended = await warm.end { sessions in Set(sessions) }
        #expect(ended == .ended)
    }

}
