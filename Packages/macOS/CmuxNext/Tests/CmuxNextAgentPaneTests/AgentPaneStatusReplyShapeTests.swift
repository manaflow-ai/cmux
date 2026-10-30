import Foundation
import Testing
@testable import CmuxNextAgentPane

/// The relay's `_acpmux/status` filter (``AcpmuxPaneMethods/replyShapes``): the page's environment
/// picker sorts peers into SSH and Cloud by transport and marks each one connected or not, so each
/// peer keeps its name, the scheme of its URL and its `connected` flag, never the URL itself
/// (which can carry a user or a token).
struct AgentPaneStatusReplyShapeTests {
    static func reply(_ result: [String: Any]) throws -> [String: Any] {
        let shape = try #require(AcpmuxPaneMethods.replyShapes["_acpmux/status"])
        let text = AcpmuxPaneMethods.filteredReply(["result": result], shape: shape, pageID: "7")
        return try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    static func peers(_ reply: [String: Any]) throws -> [[String: Any]] {
        try #require((reply["result"] as? [String: Any])?["peers"] as? [[String: Any]])
    }

    /// `value` is a JSON boolean (not a number that reads as one).
    static func isBool(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    @Test func eachPeerKeepsItsNameTransportAndConnectedButNotItsURL() throws {
        let peers = try Self.peers(Self.reply(["peers": [
            ["name": "gpu-box", "url": "ssh://dev@gpu-box", "connected": true],
            ["name": "cloud-1", "url": "wss://cloud-1.cmux.dev/acp?token=secret", "connected": false],
        ]]))
        #expect(peers.map { $0["name"] as? String } == ["gpu-box", "cloud-1"])
        #expect(peers.map { $0["transport"] as? String } == ["ssh", "wss"])
        #expect(peers.map { $0["connected"] as? Bool } == [true, false])
        #expect(peers.allSatisfy { Self.isBool($0["connected"]) })
        #expect(peers.allSatisfy { $0["url"] == nil && $0.count == 3 })
    }

    /// A chat whose machine is not connected says when it was last seen (chatUnavailable.ts): each
    /// peer keeps acpmux's link `state`, `lastSeen` and `attempts`, and nothing else it sends.
    @Test func eachPeerKeepsItsLinkStateLastSeenAndAttempts() throws {
        let peers = try Self.peers(Self.reply(["peers": [
            ["name": "laptop", "url": "ssh://me@laptop", "connected": false, "state": "reconnecting",
             "lastSeen": 1_792_600_000_000, "attempts": 4, "downSince": 1_792_600_001_000, "error": "refused"],
        ]]))
        let peer = try #require(peers.first)
        #expect(peer["state"] as? String == "reconnecting")
        #expect((peer["lastSeen"] as? NSNumber)?.int64Value == 1_792_600_000_000)
        #expect((peer["attempts"] as? NSNumber)?.intValue == 4)
        #expect(peer["downSince"] == nil && peer["error"] == nil && peer["url"] == nil)
    }

    @Test func aLastSeenThatIsNotANumberIsDropped() throws {
        let peers = try Self.peers(Self.reply(["peers": [
            ["name": "one", "lastSeen": true, "attempts": "3"],
        ]]))
        #expect(peers.first?["lastSeen"] == nil && peers.first?["attempts"] == nil)
    }

    @Test func aConnectedThatIsNotABooleanIsDropped() throws {
        let peers = try Self.peers(Self.reply(["peers": [
            ["name": "one", "connected": 1],
            ["name": "yes", "connected": "true"],
        ]]))
        #expect(peers.map { $0["name"] as? String } == ["one", "yes"])
        #expect(peers.allSatisfy { $0["connected"] == nil })
    }

    @Test func anUnknownSchemeOrAMissingURLLeavesOnlyTheName() throws {
        let reply = try Self.reply(["peers": [
            ["name": "odd", "url": "file:///etc/passwd"],
            ["name": "bare"],
        ]])
        let peers = try #require((reply["result"] as? [String: Any])?["peers"] as? [[String: String]])
        #expect(peers == [["name": "odd"], ["name": "bare"]])
    }

    @Test func cachedHealthKeepsOnlyWarningInputs() throws {
        let peers = try Self.peers(Self.reply(["peers": [[
            "name": "worker", "health": [
                "load": [14.0, 3.0, 2.0], "cpus": 16, "ram": ["freeBytes": 1_200_000_000, "totalBytes": 32_000_000_000],
                "host": "private-host", "disk": ["freeBytes": 99], "liveSessions": 5,
                "pressure": ["cores": 10, "load_limit": 10.0, "ok": false,
                             "over": ["available RAM 7% < 10%"], "host": "private-host", "warning": "private detail"],
            ],
        ]]]))
        let health = try #require(peers.first?["health"] as? [String: Any])
        #expect(health["load"] as? [Double] == [14, 3, 2])
        #expect(health["host"] == nil && health["disk"] == nil && health["liveSessions"] == nil)
        let ram = try #require(health["ram"] as? [String: Any])
        #expect((ram["freeBytes"] as? NSNumber)?.int64Value == 1_200_000_000)
        #expect(ram["totalBytes"] == nil)
        let pressure = try #require(health["pressure"] as? [String: Any])
        #expect(pressure["cores"] as? Int == 10)
        #expect(pressure["over"] as? [String] == ["available RAM 7% < 10%"])
        #expect(pressure["host"] == nil && pressure["warning"] == nil)
    }


    @Test func reconnectKeepsDoctorStateButDropsPeerEndpointsAndMetadata() throws {
        let shape = try #require(AcpmuxPaneMethods.replyShapes["_acpmux/peer_reconnect"])
        let text = AcpmuxPaneMethods.filteredReply(["result": ["peers": [
            ["name": "cloud-1", "url": "wss://cloud-1.cmux.dev/?token=secret", "connected": false,
             "state": "offline", "error": "doctor refused", "health": ["host": "hidden"]],
        ]]], shape: shape, pageID: "8")
        let reply = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let result = try #require(reply["result"] as? [String: Any])
        let peers = try #require(result["peers"] as? [[String: Any]])
        let peer = try #require(peers.first)
        #expect(peer["name"] as? String == "cloud-1")
        #expect(peer["transport"] as? String == "wss")
        #expect(peer["state"] as? String == "offline")
        #expect(peer["error"] as? String == "doctor refused")
        #expect(peer["url"] == nil && peer["health"] == nil)
    }
}
