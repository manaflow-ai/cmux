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

    @Test func everyPeerReadKeepsTheOriginalOutageAndDropsPrivateFields() throws {
        for method in ["_acpmux/peers", "_acpmux/status", "_acpmux/peer_reconnect"] {
            let shape = try #require(AcpmuxPaneMethods.replyShapes[method])
            let value: [String: Any] = ["peers": [[
                "name": "studio", "state": "reconnecting", "link": "reconnecting",
                "carrier": "ssh", "cause": "remote", "since": 200, "downSince": 100,
                "nextRetryAt": 300, "url": "ssh://private", "token": "secret",
            ]]]
            let filtered = try #require(AcpmuxPaneMethods.filtered(value, to: shape) as? [String: Any])
            let peer = try #require((filtered["peers"] as? [[String: Any]])?.first)
            #expect(peer["link"] as? String == "reconnecting")
            #expect(peer["since"] as? Int == 200)
            #expect(peer["downSince"] as? Int == 100)
            #expect(peer["nextRetryAt"] as? Int == 300)
            #expect(peer["carrier"] as? String == "ssh")
            #expect(peer["cause"] as? String == "remote")
            #expect(peer["url"] == nil && peer["token"] == nil)
        }
    }

    /// The device kinds reach the page (each machine's glyph), and nothing else rides along.
    @Test func statusKeepsDeviceKindsOnly() throws {
        let shape = try #require(AcpmuxPaneMethods.replyShapes["_acpmux/status"])
        let value: [String: Any] = [
            "device": "mac-mini", "home": "/Users/private", "pid": 7,
            "peers": [["name": "studio", "url": "ssh://private",
                       "health": ["device": "linux-server", "host": "private-host"]]],
        ]
        let filtered = try #require(AcpmuxPaneMethods.filtered(value, to: shape) as? [String: Any])
        #expect(filtered["device"] as? String == "mac-mini")
        #expect(filtered["home"] == nil && filtered["pid"] == nil)
        let peer = try #require((filtered["peers"] as? [[String: Any]])?.first)
        let health = try #require(peer["health"] as? [String: Any])
        #expect(health["device"] as? String == "linux-server")
        #expect(Set(health.keys) == ["device"])
    }
}
