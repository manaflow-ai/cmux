import Foundation
import Testing
@testable import CmuxNextAgentPane

/// The prompts pending in each session are read with one `_acpmux/info` per session. Those reads
/// are independent: a peer whose info handler stalls must not hold this Mac's own prompt, nor any
/// other session's. Run one after another, one stalled read held every read listed after it
/// (the same class as hq#9137's queued reads).
@MainActor
struct AcpmuxPendingReadsTests {
    /// An acpmux that lists a peer's session first, whose `_acpmux/info` does not answer until
    /// `release()`, then this Mac's own session, whose info answers at once.
    final class StalledPeerLine: AgentDialogLine {
        var isPerson = true
        var capabilities: Set<String> = [AcpmuxSessionListGate.pendingCapability]
        private var stalled: [CheckedContinuation<[String: Any]?, Never>] = []
        private(set) var released = false

        func call(_ method: String, _ params: [String: Any]) async -> [String: Any]? {
            switch method {
            case "_acpmux/sessions":
                return ["sessions": [
                    ["sessionId": "acp_peer_stalled", "peer": "peer-mac", "pendingPermissions": 1],
                    ["sessionId": "acp_own", "name": "own", "pendingPermissions": 1],
                ]]
            case "_acpmux/info" where params["sessionId"] as? String == "acp_peer_stalled":
                if released { return nil }
                return await withCheckedContinuation { stalled.append($0) }
            case "_acpmux/info":
                return ["pending": [["permissionId": "perm-own", "request": ["toolCall": ["title": "Run make"]]]]]
            default:
                return nil
            }
        }

        func release() {
            released = true
            let waiters = stalled
            stalled = []
            for waiter in waiters { waiter.resume(returning: nil) }
        }

        func close() { release() }
    }

    /// This Mac's prompt comes back within the per-read bound, not after the peer's stall.
    @Test func aStalledPeerReadDoesNotHoldThisMacsPrompt() async {
        let line = StalledPeerLine()
        // The peer answers on its own only after `stall`, far past any per-read bound.
        let stall: Duration = .seconds(10)
        let releaser = Task { @MainActor in
            try? await Task.sleep(for: stall)
            line.release()
        }
        let clock = ContinuousClock()
        let start = clock.now
        let prompts = await line.pendingPrompts()
        let took = clock.now - start
        releaser.cancel()
        line.release()
        #expect(prompts.map(\.permission) == ["perm-own"])
        #expect(took < .seconds(5), "this Mac's prompt waited \(took) on a peer's stalled _acpmux/info")
    }
}
