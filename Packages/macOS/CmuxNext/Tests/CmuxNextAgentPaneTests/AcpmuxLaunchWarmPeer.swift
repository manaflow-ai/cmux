import Foundation
import Testing
@testable import CmuxNextAgentPane

/// Deterministic RPC outcomes for launch-warm error and sibling-session coverage.
actor AcpmuxLaunchWarmPeer {
    private var replies: [AcpmuxLaunchWarmPeerReply]
    private(set) var requests: [[String]] = []

    init(_ replies: [AcpmuxLaunchWarmPeerReply]) { self.replies = replies }

    func reply(_ params: [String: any Sendable]) throws -> Bool {
        requests.append(params["sessionIds"] as? [String] ?? [])
        guard !replies.isEmpty else { Issue.record("unexpected warm request"); return false }
        switch replies.removeFirst() {
        case .success: return true
        case .failed: return false
        case .lost: throw AcpmuxStatusClient.Failure.closed
        case .unsupported: throw AcpmuxStatusClient.Failure.unsupportedFeature("launchWarm")
        }
    }
}
