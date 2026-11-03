import Foundation
import Testing
@testable import CmuxNextAgentPane

@Suite struct AcpmuxPanePeerSnapshotTests {
    @Test func peerSnapshotAcceptsNoParameters() {
        #expect(AcpmuxPaneMethods.requests.contains("_acpmux/peers"))
        #expect(!AcpmuxPaneMethods.breaksParamsRule(["method": "_acpmux/peers", "params": [:]], modeFields: nil))
        for params in [["command": "pwd"], ["peer": "other"], ["url": "ssh://private"]] {
            #expect(AcpmuxPaneMethods.breaksParamsRule(["method": "_acpmux/peers", "params": params], modeFields: nil))
        }
    }

    @Test func peerSnapshotKeepsOnlyDisplayFields() throws {
        let shape = try #require(AcpmuxPaneMethods.replyShapes["_acpmux/peers"])
        let value: [String: Any] = ["peers": [["name": "studio-mac", "state": "offline", "lastSeen": 5,
                                              "error": "removed", "url": "ssh://private", "token": "secret"]]]
        let filtered = try #require(AcpmuxPaneMethods.filtered(value, to: shape) as? [String: Any])
        let peer = try #require((filtered["peers"] as? [[String: Any]])?.first)
        #expect(Set(peer.keys) == ["name", "state", "lastSeen", "error"])
        #expect(peer["error"] as? String == "removed")
    }
}
