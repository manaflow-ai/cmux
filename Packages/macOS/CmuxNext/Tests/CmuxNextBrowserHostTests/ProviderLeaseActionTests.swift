@testable import CmuxNextBrowserHost
import Foundation
import Testing

/// Take over / Hand back (wow-20 idea 18, "Watch and take the wheel"): the app's
/// `lease.user` frame is the one provider.rs `Frame::LeaseUser` reads, and the
/// badge offers only the actions the host's lease state machine accepts.
@Suite struct ProviderLeaseActionTests {
    @Test func leaseUserFrameMatchesTheHostWire() throws {
        let frame = ProviderFrame.leaseUser(op: ProviderLeaseAction.takeOver.rawValue, targetID: "W", actor: nil)
        let object = ProviderCodec.jsonObject(frame)
        #expect(object["t"] as? String == "lease.user")
        #expect(object["op"] as? String == "take_over")
        #expect(object["targetId"] as? String == "W")
        #expect(object["actor"] == nil)
        let body = try JSONSerialization.data(withJSONObject: object)
        #expect(try ProviderCodec.decode(body) == frame)
    }

    @Test func offeredActionsFollowTheLeaseContract() {
        #expect(ProviderLeaseAction.offered(forWireState: "driving") == [.takeOver, .stop])
        #expect(ProviderLeaseAction.offered(forWireState: nil) == [.takeOver, .stop])
        #expect(ProviderLeaseAction.offered(forWireState: "paused") == [.takeOver, .handBack, .stop])
        #expect(ProviderLeaseAction.offered(forWireState: "user_driving") == [.handBack, .stop])
    }

    @Test func opsAreTheHostsNames() {
        #expect(ProviderLeaseAction.allCases.map(\.rawValue) == ["take_over", "hand_back", "stop"])
    }
}
