import Foundation
import Testing
@testable import CmuxNextAgentPane

/// Deterministic RPC seam for launch-warm fencing tests.
actor AcpmuxLaunchWarmPeer {
    private var replies: [Int]
    private let retryFence: AcpmuxLaunchWarm.Fence
    private(set) var requests: [(String?, UInt64?)] = []

    init(_ replies: [Int], retryFence: AcpmuxLaunchWarm.Fence = .init(epoch: "123:456", stops: 7)) {
        self.replies = replies
        self.retryFence = retryFence
    }

    func reply(_ params: [String: any Sendable]) throws -> AcpmuxLaunchWarm.Fence? {
        requests.append((params["expectedDaemonEpoch"] as? String,
                         (params["expectedStopCounts"] as? [String: UInt64])?["chat"]))
        guard !replies.isEmpty else { Issue.record("unexpected warm retry"); return nil }
        switch replies.removeFirst() {
        case 0: return retryFence
        case 1: throw AcpmuxStatusClient.Failure.closed
        default: return nil
        }
    }
}
