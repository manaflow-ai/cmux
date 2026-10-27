import Foundation
import Testing
@testable import CmuxNextAgentPane

actor AcpmuxLaunchWarmPeer {
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
