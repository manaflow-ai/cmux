@testable import CmuxNextAgentPane
import CmuxNextSettings
import Foundation
import Testing

/// Leo 2026-11-25, on enrolling remote machines into AutoCloud: "would it make sense to enroll remote
/// machines aka stuff like [one of our Macs] capable into the autocloud, or just keep remote as it normally
/// would be". Each peer's `health.autoCloud` (RFD 0172) becomes the read-only AutoCloud line on its
/// Settings > Machines row, found by its acpmux name or its `ssh://` host.
struct PeerAutoCloudStoreTests {
    static let report: [String: Any] = [
        "v": 1, "enrolled": true, "accepting": false, "ownerIdle": false, "ownerIdleSecs": 12, "inHours": true,
        "policy": ["teams": ["team-a"], "agents": ["claude"], "hours": ["from": 22, "to": 7]],
        "caps": ["arm64", "macos", "xcode"], "why": "owner active",
    ]

    @Test func peerListReadsEachMachinesAutoCloudReport() {
        let peers = AcpmuxPeerList.peers(["peers": [
            ["name": "studio", "connected": true, "url": "ssh://me@studio.local:22", "health": ["autoCloud": Self.report]],
            ["name": "old", "connected": true, "health": ["os": "macos"]],
        ]])
        let expected = AcpmuxPeerList.AutoCloud(enrolled: true, accepting: false, ownerIdle: false, teams: ["team-a"], agents: ["claude"],
                                                hours: .init(from: 22, to: 7), caps: ["arm64", "macos", "xcode"])
        #expect(peers.map(\.autoCloud) == [expected, nil])
        let index = PeerAutoCloudStore.index(peers)
        #expect(index["studio"] == expected && index["studio.local"] == expected && index["old"] == nil)
    }

    @Test func rowJSONMatchesThePagesShape() {
        let report = AcpmuxPeerList.AutoCloud(enrolled: true, accepting: true, caps: ["macos"])
        let row = PeerAutoCloudStore.rowJSON(report)
        #expect(row == ["on": true, "error": nil, "accepting": true, "caps": ["macos"],
                        "policy": ["teams": [], "agents": [], "hours": nil]],
                "no idle reading leaves owner_idle out; no hours is any hour")
    }
}
