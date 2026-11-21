import CmuxNextAgentActivity
@testable import CmuxNextAgentLanes
@testable import CmuxNextAgentPane
import CmuxNextBridge
import Foundation
import Testing

/// acpmux pushes each peer's link state (`_acpmux/peer_state_changed`) to the app's own watch:
/// only this Mac's own daemon's pushes count.
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
}
