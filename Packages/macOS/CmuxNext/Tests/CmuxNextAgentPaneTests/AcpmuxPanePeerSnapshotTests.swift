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

    @Test func moveTargetsAcceptsOnlyItsOptionalSourceSelectors() {
        #expect(AcpmuxPaneMethods.requests.contains("_acpmux/move_targets"))
        for params in [[:], ["source": "studio"], ["sourceKind": "ssh"],
                       ["source": "studio", "sourceKind": "ssh"]] {
            #expect(!AcpmuxPaneMethods.breaksParamsRule([
                "method": "_acpmux/move_targets", "params": params,
            ], modeFields: nil))
        }
        for params in [["url": "ssh://private"], ["host": "private"], ["sessionId": "chat"]] {
            #expect(AcpmuxPaneMethods.breaksParamsRule([
                "method": "_acpmux/move_targets", "params": params,
            ], modeFields: nil))
        }
    }

    @Test func moveTargetsKeepLabelsAndDropEndpointsAndMetadata() throws {
        let shape = try #require(AcpmuxPaneMethods.replyShapes["_acpmux/move_targets"])
        let value: [String: Any] = [
            "targets": [[
                "id": "ssh:studio", "label": "Studio", "kind": "ssh", "status": "ready",
                "reason": "", "room": 3.0, "url": "ssh://private", "host": "private",
            ]],
            "pick": "ssh:studio",
            "debug": "hidden",
        ]
        let filtered = try #require(AcpmuxPaneMethods.filtered(value, to: shape) as? [String: Any])
        let target = try #require((filtered["targets"] as? [[String: Any]])?.first)
        let fields = Set(["id", "label", "kind", "status", "reason", "room"])
        #expect(Set(target.keys) == fields)
        #expect((target["room"] as? NSNumber)?.doubleValue == 3)
        #expect(filtered["pick"] as? String == "ssh:studio")
        #expect(target["url"] == nil && target["host"] == nil)
        #expect(filtered["debug"] == nil)
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
