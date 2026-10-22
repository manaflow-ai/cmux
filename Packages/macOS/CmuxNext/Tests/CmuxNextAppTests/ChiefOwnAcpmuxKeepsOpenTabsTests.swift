import Foundation
import Testing
@testable import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextDaemon
@testable import CmuxNextHomeEngine

/// Lawrence, 2026-10-21 (follow-up to "This chat isn't available"): old Chief subagent tabs now
/// attach to the Chief home's own acpmux, and a later Chief start ended that daemon once no
/// session was in a turn, cutting an open tab's connection. The daemon ends only when no client
/// is attached to any of its sessions. Named Chiefs (`c/<id>`) share that daemon: their tabs were
/// classed as another machine's and refused; they now attach like the Chief's.
struct ChiefOwnAcpmuxKeepsOpenTabsTests {
    @Test func aDaemonWithAnAttachedTabIsNotIdle() {
        #expect(ChiefAppAcpmuxMove.idle(AcpmuxSessionCensus(live: 0)))
        #expect(!ChiefAppAcpmuxMove.idle(AcpmuxSessionCensus(live: 0, attached: 1)))
    }

    @Test func theCensusCountsAttachedSessions() {
        let listing: [String: Any] = ["sessions": [
            ["sessionId": "a", "status": "idle", "attached": 1],
            ["sessionId": "b", "status": "idle", "attached": 0],
            ["sessionId": "c", "status": "ready", "attached": 2],
        ]]
        #expect(AcpmuxSessionCensus.parse(listing).attached == 2)
    }

    @Test func aNamedChiefsTabAttachesLikeTheChiefs() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("chief-named-\(UUID().uuidString)/chief/default", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent().deletingLastPathComponent()) }
        let named = root.appendingPathComponent("c/0d4bs6c3", isDirectory: true)
        try FileManager.default.createDirectory(at: named, withIntermediateDirectories: true)
        let home = ChiefHome(root: root, isolated: false, buildID: ChiefHome.nightlyBundleID)
        let host = ChiefHomeAcpmux.host(muxHome: named)
        #expect(ChiefHomeAcpmux.namedHosts(home: home) == [host])
        let record = AgentSessionRef(host: host, session: "01a156e6-8644", harness: "claude-sr2")
        #expect(AgentPaneHostKind(record, localHost: "install:mac", chiefHost: ChiefHomeAcpmux.host(muxHome: root),
                                  namedChiefHosts: ChiefHomeAcpmux.namedHosts(home: home)) == .chief)
        // Its sessions carry its own parent tag in the shared daemon's listing.
        let tag = "optchat-chief:" + host.dropFirst("chief:".count)
        let listing: [String: Any] = ["sessions": [["sessionId": "01a156e6-8644", "tags": ["mux.parent": tag]]]]
        #expect(AcpmuxChiefSessionRouter.owns(listing, session: "01a156e6-8644", parentTags: ["optchat-chief:main", tag]))
    }
}
