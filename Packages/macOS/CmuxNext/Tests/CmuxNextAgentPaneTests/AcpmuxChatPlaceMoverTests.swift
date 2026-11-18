import Foundation
import Testing
@testable import CmuxNextAgentPane

/// Auto chat placement's mover reads the daemon's `chatPlace/move` and names the Move to… target the
/// app's own action takes; the sleep gate always lets idle sleep through and holds only a coming sleep.
struct AcpmuxChatPlaceMoverTests {
    @Test func aMoveToCloudTakesAnyCloudMachineAndBringBackThisMac() throws {
        let cloud = try #require(AcpmuxChatPlaceMover.Move(params: ["session": "s1", "to": "cloud", "peer": NSNull(), "why": "lid closed", "back": false]))
        #expect(cloud == AcpmuxChatPlaceMover.Move(session: "s1", to: .cloud, why: "lid closed"))
        #expect(cloud.target == "")
        let back = try #require(AcpmuxChatPlaceMover.Move(params: ["session": "s1", "to": "local", "why": "This Mac is back", "back": true]))
        #expect(back.back)
        #expect(back.target == AgentPaneMoveTarget.localID)
    }

    @Test func aMoveToAJoinedMachineIsNeverTheApps() throws {
        let peer = try #require(AcpmuxChatPlaceMover.Move(params: ["session": "s1", "to": "peer", "peer": "huge-blue"]))
        #expect(peer.peer == "huge-blue")
        #expect(peer.target == nil)
    }

    @Test func aMalformedMoveIsDropped() {
        #expect(AcpmuxChatPlaceMover.Move(params: ["to": "cloud"]) == nil)
        #expect(AcpmuxChatPlaceMover.Move(params: ["session": "", "to": "cloud"]) == nil)
        #expect(AcpmuxChatPlaceMover.Move(params: ["session": "s1", "to": "mars"]) == nil)
        #expect(AcpmuxChatPlaceMover.Move(params: ["session": "s1", "to": "peer", "peer": ""]) == nil)
    }

    @Test func theSleepGateHoldsOnlyAComingSleep() {
        #expect(ChatPlaceSleepGate.decision(for: ChatPlaceSleepGate.canSystemSleep) == .allow)
        #expect(ChatPlaceSleepGate.decision(for: ChatPlaceSleepGate.systemWillSleep) == .holdThenAllow)
        #expect(ChatPlaceSleepGate.decision(for: ChatPlaceSleepGate.systemHasPoweredOn) == .wake)
        #expect(ChatPlaceSleepGate.decision(for: 0xE000_0320) == .ignore)
    }
}
