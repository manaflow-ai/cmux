@testable import CmuxNextDevices
import Foundation
import Testing

/// Leo: "i dont want to have to click share this mac allow every single time when screen sharing". A request
/// from one of his own devices with consent here (acpmux decides, through ``DeviceHub/autoApprove``) is answered
/// Allow once with no approval panel, on every request and after a restart; anything else reaches the panel.
@MainActor @Suite struct DeviceHubAutoApproveTests {
    let me = DeviceIdentity.software()
    static let decided = (200, #"{"session":{"id":"s1","state":"approved","scope":"full"}}"#)

    func makeHub(_ stub: StubHub) -> DeviceHub {
        DeviceHub(client: makeClient(stub, identity: me), secrets: MemoryRelaySecretStore(), deviceName: "Studio", now: fixedNow)
    }

    static func request(_ id: String, scope: SessionScope = .full) -> SessionRequest {
        SessionRequest(id: id, viewerId: "d-phone", viewerName: "Phone", scope: scope)
    }

    /// Allowed: answered `once` (never `always`, so turning consent off in acpmux stops the next one), nothing
    /// pending. A second request is asked again and answered again, and so is one to a new hub (a restart).
    @Test func anAllowedRequestIsAnsweredOnceWithNoPanelEveryTime() async {
        let stub = StubHub.routes(["POST /v1/sessions/s1/decision": Self.decided, "POST /v1/sessions/s2/decision": Self.decided,
                                   "POST /v1/sessions/s3/decision": Self.decided])
        var asked: [SessionRequest] = []
        let hub = makeHub(stub)
        hub.autoApprove = { asked.append($0); return true }
        var seen = 0
        hub.onSessionPush = { _ in seen += 1 }
        await hub.handle(.push(.sessionRequest(Self.request("s1"))))
        #expect(hub.pendingRequests.isEmpty)
        let decision = stub.requests.first { $0.url.path == "/v1/sessions/s1/decision" }
        #expect(decision?.jsonBody?["decision"] as? String == "once" && decision?.jsonBody?["scope"] as? String == "full")
        await hub.handle(.push(.sessionRequest(Self.request("s2", scope: .view))))
        #expect(hub.pendingRequests.isEmpty && asked.map(\.id) == ["s1", "s2"] && seen == 2)
        let restarted = makeHub(stub)
        restarted.autoApprove = { _ in true }
        await restarted.handle(.push(.sessionRequest(Self.request("s3"))))
        #expect(restarted.pendingRequests.isEmpty)
        #expect(stub.requests.filter { $0.url.path.hasSuffix("/decision") }.count == 3)
    }

    /// Refused, a failed answer, or no check at all: the panel asks as before, and nothing is decided here.
    @Test func aRefusedOrFailedCheckReachesThePanel() async {
        let stub = StubHub.routes([:])
        let hub = makeHub(stub)
        await hub.handle(.push(.sessionRequest(Self.request("s1"))))
        hub.autoApprove = { _ in false }
        await hub.handle(.push(.sessionRequest(Self.request("s2"))))
        hub.autoApprove = { _ in true } // the hub's answer fails (no route): the panel still asks
        await hub.handle(.push(.sessionRequest(Self.request("s3"))))
        #expect(hub.pendingRequests.map(\.id) == ["s1", "s2", "s3"])
        #expect(stub.requests.filter { $0.url.path.hasSuffix("/decision") }.map(\.url.path) == ["/v1/sessions/s3/decision"])
    }
}
