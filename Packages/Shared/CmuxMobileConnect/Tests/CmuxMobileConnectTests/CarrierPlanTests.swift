import CmuxLink
import CmuxLinkDirect
import CmuxMobileConnect
import Foundation
import Testing

@Suite("carrier plan")
struct CarrierPlanTests {
    static let key = DirectIdentity().publicKey
    static let lan = DirectEndpoint(address: DirectAddress("192.168.1.20")!, hostKey: key)
    static let wifi = DirectPathSnapshot(isSatisfied: true, interfaces: [DirectInterface(name: "en0", kind: .wifi)])
    static let cellular = DirectPathSnapshot(isSatisfied: true, interfaces: [DirectInterface(name: "pdp_ip0", kind: .cellular)])

    @Test("a workable direct route races alone; without one the others race")
    func gating() {
        let plan = MobileCarrierPlan(endpoints: [Self.lan], snapshot: Self.wifi)
        #expect(plan.admits(.direct) && !plan.admits(.webrtc) && !plan.admits(.webrtcWireGuard))
        plan.update(snapshot: Self.cellular)
        #expect(!plan.admits(.direct) && plan.admits(.webrtc))
        plan.update(endpoints: [])
        plan.update(snapshot: Self.wifi)
        #expect(!plan.admits(.direct) && plan.admits(.webrtc))
    }

    @Test("before the first snapshot every carrier races")
    func unknownPath() {
        let plan = MobileCarrierPlan(endpoints: [Self.lan], snapshot: nil)
        #expect(plan.admits(.direct) && plan.admits(.webrtc))
    }

    @Test("forced direct excludes WebRTC even when the route is unreachable")
    func forcedDirect() {
        let plan = MobileCarrierPlan(endpoints: [Self.lan], snapshot: Self.cellular, transport: .direct)
        #expect(plan.admits(.direct) && !plan.admits(.webrtc) && !plan.admits(.webrtcWireGuard))
    }

    @Test("forced WebRTC excludes direct even when a LAN route is available")
    func forcedWebRTC() {
        let plan = MobileCarrierPlan(endpoints: [Self.lan], snapshot: Self.wifi, transport: .webrtc)
        #expect(!plan.admits(.direct) && plan.admits(.webrtc) && plan.admits(.webrtcWireGuard))
    }

    @Test("a reachable Mac that does not answer lets the others race until the path changes")
    func directFailed() async {
        let plan = MobileCarrierPlan(endpoints: [Self.lan], snapshot: Self.wifi)
        let failing = PlannedCarrier(FailingCarrier(), plan: plan)
        await #expect(throws: (any Error).self) { try await failing.connect(to: LinkPeer(hostID: "h")) }
        #expect(plan.directFailed && plan.admits(.direct) && plan.admits(.webrtc))
        plan.update(snapshot: Self.wifi)
        #expect(!plan.directFailed && !plan.admits(.webrtc))
    }

    @Test("an excluded carrier fails at once without dialing")
    func excluded() async {
        let plan = MobileCarrierPlan(endpoints: [Self.lan], snapshot: Self.wifi)
        let other = PlannedCarrier(FailingCarrier(kind: .webrtc), plan: plan)
        await #expect(throws: MobileConnectError.excludedByPlan(.webrtc)) { try await other.connect(to: LinkPeer(hostID: "h")) }
    }
}

private struct FailingCarrier: LinkCarrier {
    var kind: CarrierKind = .direct
    var candidatePaths: [PathKind] { [.direct] }
    func connect(to peer: LinkPeer) async throws -> any LinkTransport { throw LinkError.allCarriersFailed(["refused"]) }
}
