import Foundation
import Testing
@testable import CmuxNextDaemon

/// The app's side of `apps-run` (a catalog op of an app server) and of the
/// app server events that come back on the same connection.
@MainActor @Suite struct AppsRunWireTests {
    @Test func appsRunCarriesTheOpItsArgsKeyAndOrigin() throws {
        let request = AppsRunRequest(app: "cmux/cloud", op: "cloud.machine.connect",
                                     args: .object(["machine": .string("vm_1")]), idempotencyKey: "k1", origin: .user)
        let data = try WireCoding.encodeRequest(request, id: 3)
        guard case .object(let json) = try JSONDecoder().decode(JSONValue.self, from: data) else {
            Issue.record("not an object")
            return
        }
        #expect(json["cmd"] == .string("apps-run"))
        #expect(json["id"] == .number(3))
        #expect(json["app"] == .string("cmux/cloud"))
        #expect(json["op"] == .string("cloud.machine.connect"))
        #expect(json["args"] == .object(["machine": .string("vm_1")]))
        #expect(json["idempotency_key"] == .string("k1"))
        #expect(json["origin"] == .string("user"))
    }

    @Test func theAnswerIsTheOpResult() throws {
        let line = Data(#"{"id":3,"ok":true,"data":{"machine":"vm_1","state":"up","socket":"/tmp/x/l.sock"}}"#.utf8)
        let result = try WireCoding.decodeResponse(AppsRunRequest.Response.self, from: line)
        #expect(result["socket"] == .string("/tmp/x/l.sock"))
    }

    @Test func appServerEventsReachSideEventSubscribers() {
        let store = DaemonStore()
        var seen: [AppServerEvent] = []
        store.sideEvents.subscribe { event in
            if let event = AppServerEvent(event) { seen.append(event) }
        }
        let payload: JSONValue = .object(["event": .string("apps-server-event"), "app": .string("cmux/cloud"),
                                          "name": .string("cmux.cloud.link.changed"),
                                          "data": .object(["machine": .string("vm_1"), "state": .string("down")])])
        _ = store.apply(.unknown(name: "apps-server-event", payload: payload))
        _ = store.apply(.unknown(name: "something-else", payload: .null))
        #expect(seen == [AppServerEvent(app: "cmux/cloud", name: "cmux.cloud.link.changed", payload: payload)])
    }
}
