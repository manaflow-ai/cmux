import Foundation
import Testing
@testable import CmuxNextAgentPane

/// The relay's `_acpmux/status` filter keeps each peer's load row (`peers[].load`, acpmux
/// placement.rs `load_row`), which the machine picker draws, and drops anything else in it.
struct AgentPaneStatusLoadRowShapeTests {
    @Test func eachPeerKeepsItsLoadRowAndNothingElseInIt() throws {
        let peers = try AgentPaneStatusReplyShapeTests.peers(AgentPaneStatusReplyShapeTests.reply(["peers": [
            ["name": "gcp-3", "url": "ssh://me@gcp-3", "connected": true, "load": [
                "verdict": "room", "words": "room for 5", "room": 5, "coresBusy": 3.2, "cores": 16,
                "ramFreeBytes": 24_000_000_000, "live": 2, "offlineMs": NSNull(), "url": "ssh://me@gcp-3",
            ]],
        ]]))
        let load = try #require(peers.first?["load"] as? [String: Any])
        #expect(load["verdict"] as? String == "room")
        #expect(load["words"] as? String == "room for 5")
        #expect((load["coresBusy"] as? NSNumber)?.doubleValue == 3.2)
        #expect((load["live"] as? NSNumber)?.intValue == 2)
        #expect(load["url"] == nil && load["offlineMs"] == nil)
    }

    @Test func theSidebarReadsTheVerdictWordsFromTheSameRow() {
        let peers = AcpmuxPeerList.peers(["peers": [
            ["name": "gcp-3", "connected": true,
             "health": ["load": [3.2], "cpus": 16, "ram": ["freeBytes": 24_000_000_000], "pressure": ["ok": true, "cores": 16]],
             "load": ["verdict": "room", "words": "room for 5"]],
        ]])
        #expect(peers.first?.resources?.verdict == "room for 5")
    }
}
