import CmuxNextApps
import CmuxNextDaemon
import Foundation
import Testing
@testable import CmuxNextApp

/// The `apps-v1` wire shapes: request fields in snake_case with JSON
/// payload keys untouched, and the supervisor's replies and events.
@MainActor
struct AppsWireTests {
    private func wire<R: DaemonRequest>(_ request: R) throws -> AppJSON {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return try AppJSON.parse(encoder.encode(request))
    }

    @Test func setEncodesOnlyTheChangedFieldsAndTheOrigin() throws {
        let json = try wire(AppsSetRequest(app: "cmux/x", change: .grant("net:api.github.com", false), origin: .user, idempotencyKey: "k1"))
        #expect(json == ["app": "cmux/x", "idempotency_key": "k1", "origin": "user",
                         "grant": ["scope": "net:api.github.com", "granted": false]])
    }

    @Test func payloadKeysKeepTheirCase() throws {
        let context: AppJSON = ["contribution": "cmux/x#s", "preview": true, "camelKey": 1]
        let json = try wire(AppsMountRequest(app: "cmux/x", interface: "cmux.section/1", mountID: "m1", context: context.daemonValue))
        #expect(json["mount_id"] == "m1")
        #expect(json["context"]?["camelKey"] == 1)
        let payload: AppJSON = ["selectedID": "a"]
        let dispatch = try wire(AppsDispatchRequest(mountID: "m1", node: "n", event: "tap", payload: payload.daemonValue))
        #expect(dispatch["payload"]?["selectedID"] == "a")
        #expect(dispatch["origin"] == "user")
    }

    @Test func eventsDecode() throws {
        let scene = try JSONDecoder().decode(JSONValue.self, from: Data(#"""
        {"event":"apps-scene","mount_id":"m1","ops":[{"op":"create","id":"n1","type":"Text","props":{"text":"hi"}},{"op":"root","id":"n1"}]}
        """#.utf8))
        #expect(AppsEventDecoding.event(name: "apps-scene", payload: scene)
            == .scene(mountID: "m1", ops: [.create(id: "n1", type: "Text", props: ["text": "hi"]), .root(id: "n1")]))
        let host = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"event":"apps-host","app":"cmux/x","state":"crashed","reason":"oom"}"#.utf8))
        #expect(AppsEventDecoding.event(name: "apps-host", payload: host) == .host(app: "cmux/x", state: .crashed, reason: "oom"))
        let changed = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"event":"apps-changed","revision":7,"transaction":"t"}"#.utf8))
        #expect(AppsEventDecoding.event(name: "apps-changed", payload: changed) == .changed(revision: 7))
        #expect(AppsEventDecoding.event(name: "apps-unknown-future", payload: .null) == nil)
    }

    @Test func listReplyReadsRecords() throws {
        let record = try #require(FakeAppsTransport.sampleRecords().first)
        let reply = AppsEventDecoding.list(record.json.daemonValue.wrapped(revision: 3))
        #expect(reply.revision == 3)
        #expect(reply.apps == [record])
    }
}

private extension JSONValue {
    func wrapped(revision: Int) -> JSONValue { .object(["revision": .number(Double(revision)), "apps": .array([self])]) }
}
