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
                     AcpmuxPeerList.Peer(name: "big-red", connected: false)]
        guard case .list(let down) = RemoteMachinesSidebar.push(peer: "huge-blue", state: "reconnecting", onto: peers) else {
            Issue.record("a listed peer that drops moves now")
            return
        }
        #expect(down[0] == AcpmuxPeerList.Peer(name: "huge-blue", connected: false, url: "ssh://huge-blue") && down[1] == peers[1])
        #expect(RemoteMachinesSidebar.push(peer: "huge-blue", state: "connected", onto: peers) == .same)
        #expect(RemoteMachinesSidebar.push(peer: "big-red", state: "connecting", onto: peers) == .same)
        guard case .list(let up) = RemoteMachinesSidebar.push(peer: "big-red", state: "connected", onto: peers) else {
            Issue.record("a listed peer that connects moves now")
            return
        }
        #expect(up[1].connected)
    }

    @Test func anUnknownOrRemovedPeerOrAReopenedWatchReadsTheListAgain() {
        let peers = [AcpmuxPeerList.Peer(name: "big-red", connected: false)]
        #expect(RemoteMachinesSidebar.push(peer: "cmux16", state: "connected", onto: peers) == .read)
        #expect(RemoteMachinesSidebar.push(peer: "big-red", state: "offline", onto: peers) == .read)
        #expect(RemoteMachinesSidebar.push(peer: nil, state: nil, onto: peers) == .read)
        #expect(RemoteMachinesSidebar.push(peer: "big-red", state: "connected", onto: nil) == .read)
    }
}
