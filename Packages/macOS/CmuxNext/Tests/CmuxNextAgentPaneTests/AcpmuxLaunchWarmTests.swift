import Foundation
import Testing
@testable import CmuxNextAgentPane

struct AcpmuxLaunchWarmTests {
    @Test func anAmbiguousFirstReplyIsNeverRetriedWithoutAStopFence() async throws {
        let peer = WarmPeer([.lost])
        let warm = AcpmuxLaunchWarm { _, params in try await peer.reply(params) }
        // The daemon accepted the call, but its reply was lost. A person may Stop at any time.
        try await warm.warm(["chat"], socket: "unused")
        #expect(await peer.requests.count == 1)
    }

    @Test func retriesKeepTheOriginalFenceThroughLostRepliesAndStopAfterAnEpochMismatch() async throws {
        let fence = AcpmuxLaunchWarm.Fence(epoch: "123:456", stops: 7)
        let peer = WarmPeer([.retry(fence), .lost, .skip])
        let warm = AcpmuxLaunchWarm { _, params in try await peer.reply(params) }
        for _ in 0..<2 {
            await #expect(throws: AgentPaneWarmFailure.self) { try await warm.warm(["chat"], socket: "unused") }
        }
        // A new daemon returns an intentional skip for the old epoch, with no retryable failure.
        try await warm.warm(["chat"], socket: "unused")
        let requests = await peer.requests
        #expect(requests.count == 3)
        #expect(requests[0].epoch == nil)
        #expect(requests.dropFirst().allSatisfy { $0.epoch == fence.epoch && $0.stops == fence.stops })
    }

    @Test func onlyAReplyWithBothLaunchAndStopGenerationAllowsRetry() {
        let failure: [String: Any] = ["sessionId": "chat", "retryable": true, "stops": 2]
        #expect(AcpmuxLaunchWarm.Fence(result: ["failed": [failure]]) == nil)
        #expect(AcpmuxLaunchWarm.Fence(result: ["daemonEpoch": "1:2", "failed": [failure]]) == .init(epoch: "1:2", stops: 2))
        #expect(AcpmuxLaunchWarm.Fence(result: ["daemonEpoch": "1:2", "failed": []]) == nil)
    }

    private actor WarmPeer {
        enum Reply: Sendable { case retry(AcpmuxLaunchWarm.Fence), lost, skip }
        struct Request: Sendable { let epoch: String?; let stops: UInt64? }
        private var replies: [Reply]
        private(set) var requests: [Request] = []
        init(_ replies: [Reply]) { self.replies = replies }
        func reply(_ params: [String: any Sendable]) throws -> AcpmuxLaunchWarm.Fence? {
            requests.append(Request(epoch: params["expectedDaemonEpoch"] as? String,
                                    stops: (params["expectedStopCounts"] as? [String: UInt64])?["chat"]))
            guard !replies.isEmpty else { Issue.record("unexpected warm retry"); return nil }
            switch replies.removeFirst() {
            case .retry(let fence): return fence
            case .lost: throw AcpmuxStatusClient.Failure.closed
            case .skip: return nil
            }
        }
    }

}