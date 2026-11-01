import CmuxNextAgentActivity
@testable import CmuxNextAgentLanes
@testable import CmuxNextAgentPane
import CmuxNextBridge
import Foundation
import Testing

/// acpmux pushes each peer's link state (`_acpmux/peer_state_changed`) to the app's own watch:
/// the remote machines' headers follow it, and only this Mac's own daemon's pushes count.
@MainActor
struct PeerStatePushTests {
    final class Heard { var peers: [String?] = [] }

    @Test func theWatchReadsAPeerStatePush() {
        let line = #"{"jsonrpc":"2.0","method":"_acpmux/peer_state_changed","params":{"peer":"huge-blue","state":"reconnecting","lastSeen":1,"error":null,"at":2}}"#
        guard case .peerState(let peer, let state) = AgentTurnStateFeed.Message(line: Data(line.utf8)) else {
            Issue.record("not a peer state")
            return
        }
        #expect(peer == "huge-blue" && state == "reconnecting")
        let nameless = #"{"method":"_acpmux/peer_state_changed","params":{"state":"connected"}}"#
        #expect(AgentTurnStateFeed.Message(line: Data(nameless.utf8)) == nil)
    }

    @Test func onlyThisMacsOwnAcpmuxPushesReachTheSidebar() {
        let heard = Heard()
        let mirror = AgentTurnStateFeed(socketPath: "/nonexistent/mirror.sock", turns: AgentTurnStateStore(),
                                        lanes: AgentLaneStore(), mirroring: "chief:test")
        mirror.peerStateChanged = { peer, _ in heard.peers.append(peer) }
        mirror.handle(.peerState(peer: "huge-blue", state: "offline"))
        #expect(heard.peers.isEmpty, "a mirrored acpmux's peer states are not this Mac's links")
        let own = AgentTurnStateFeed(socketPath: "/nonexistent/own.sock", turns: AgentTurnStateStore(), lanes: AgentLaneStore())
        own.peerStateChanged = { peer, _ in heard.peers.append(peer) }
        own.handle(.peerState(peer: "huge-blue", state: "offline"))
        #expect(heard.peers == ["huge-blue"])
    }

    @Test func aListedPeerFollowsAtOnceAndARepeatChangesNothing() {
        let peers = [AcpmuxPeerList.Peer(name: "huge-blue", connected: true, url: "ssh://huge-blue"),
                     AcpmuxPeerList.Peer(name: "peer-a", connected: false)]
        guard case .list(let down) = RemoteMachinesSidebar.push(peer: "huge-blue", state: "reconnecting", onto: peers) else {
            Issue.record("a listed peer that drops moves now")
            return
        }
        #expect(down[0] == AcpmuxPeerList.Peer(name: "huge-blue", connected: false, url: "ssh://huge-blue") && down[1] == peers[1])
        #expect(RemoteMachinesSidebar.push(peer: "huge-blue", state: "connected", onto: peers) == .same)
        #expect(RemoteMachinesSidebar.push(peer: "peer-a", state: "connecting", onto: peers) == .same)
        guard case .list(let up) = RemoteMachinesSidebar.push(peer: "peer-a", state: "connected", onto: peers) else {
            Issue.record("a listed peer that connects moves now")
            return
        }
        #expect(up[1].connected)
    }

    /// Each `_acpmux/peers` read waits here until the test answers it.
    actor PeerReads {
        private var waiting: [CheckedContinuation<[AcpmuxPeerList.Peer]?, Never>] = []
        private(set) var count = 0
        func read() async -> [AcpmuxPeerList.Peer]? {
            count += 1
            return await withCheckedContinuation { waiting.append($0) }
        }
        func answer(_ peers: [AcpmuxPeerList.Peer]?) -> Bool {
            guard !waiting.isEmpty else { return false }
            waiting.removeFirst().resume(returning: peers)
            return true
        }
    }

    /// Yields until `done` holds, at most a bounded number of times.
    static func settle(_ done: () async -> Bool) async -> Bool {
        for _ in 0..<2_000 {
            if await done() { return true }
            await Task.yield()
        }
        return await done()
    }

    @Test func aPushDuringAReadIsFollowedByOneMoreRead() async {
        let reads = PeerReads()
        let sidebar = RemoteMachinesSidebar(lanes: AgentLaneStore())
        sidebar.bind(host: .init(peers: { await reads.read() }, older: { _, _ in nil }, displayName: { _ in nil }, open: { _ in }))
        #expect(await Self.settle { await reads.count == 1 }, "bind reads the list")
        // A push arrives while that read is in flight: its answer may be from before the push.
        sidebar.peerStateChanged(peer: "huge-blue", state: "connected")
        #expect(await reads.answer([AcpmuxPeerList.Peer(name: "huge-blue", connected: false)]))
        #expect(await Self.settle { await reads.count == 2 }, "the overtaken answer is followed by one more read")
        #expect(await reads.answer([AcpmuxPeerList.Peer(name: "huge-blue", connected: false)]))
        // Listed down now. A read samples it up between two pushes; a lagging `reconnecting` then
        // changes nothing shown, but the read's answer is from before it: dropped, read again.
        sidebar.peerStateChanged(peer: nil, state: nil)
        #expect(await Self.settle { await reads.count == 3 })
        sidebar.peerStateChanged(peer: "huge-blue", state: "reconnecting")
        #expect(await reads.answer([AcpmuxPeerList.Peer(name: "huge-blue", connected: true)]))
        #expect(await Self.settle { await reads.count == 4 }, "a push that changed nothing still drops the read it overtook")
        #expect(await reads.answer([AcpmuxPeerList.Peer(name: "huge-blue", connected: false)]))
        sidebar.stop()
        sidebar.peerStateChanged(peer: "huge-blue", state: "offline")
        for _ in 0..<50 { await Task.yield() }
        #expect(await reads.count == 4, "nothing reads after stop()")
    }

    @Test func anUnknownOrRemovedPeerOrAReopenedWatchReadsTheListAgain() {
        let peers = [AcpmuxPeerList.Peer(name: "peer-a", connected: false)]
        #expect(RemoteMachinesSidebar.push(peer: "cmux16", state: "connected", onto: peers) == .read)
        #expect(RemoteMachinesSidebar.push(peer: "peer-a", state: "offline", onto: peers) == .read)
        #expect(RemoteMachinesSidebar.push(peer: nil, state: nil, onto: peers) == .read)
        #expect(RemoteMachinesSidebar.push(peer: "peer-a", state: "connected", onto: nil) == .read)
    }
}
