import Foundation
import Testing
@testable import CmuxNextDaemon

/// The app's side of the provider channel (cmux-tui-core `apps/provider.rs`):
/// `apps-provider-register`, `apps-provider-result`, and the request and
/// cancel events that reach the side event subscribers.
@MainActor @Suite struct AppsProviderWireTests {
    @Test func registerNamesItsFamilies() throws {
        let data = try WireCoding.encodeRequest(AppsProviderRegisterRequest(families: ["credential"]), id: 2)
        #expect(try JSONDecoder().decode(JSONValue.self, from: data)
            == .object(["id": .number(2), "cmd": .string("apps-provider-register"), "families": .array([.string("credential")])]))
    }

    /// The result body is the op's own JSON: sent unchanged, never snake cased.
    @Test func resultCarriesTheRequestIDAndTheBodyVerbatim() throws {
        let body: JSONValue = .object(["value": .object(["nextCursor": .null]), "revision": .string("3")])
        let data = try WireCoding.encodeRequest(AppsProviderResultRequest(requestID: 41, ok: true, body: body), id: 9)
        #expect(try JSONDecoder().decode(JSONValue.self, from: data)
            == .object(["id": .number(9), "cmd": .string("apps-provider-result"), "request_id": .number(41), "ok": .bool(true), "body": body]))
    }

    @Test func requestAndCancelEventsReachSideEventSubscribers() {
        let store = DaemonStore()
        var calls: [AppsProviderCall] = []
        var cancels: [AppsProviderCancel] = []
        store.sideEvents.subscribe { event in
            if let call = AppsProviderCall(event) { calls.append(call) }
            if let cancel = AppsProviderCancel(event) { cancels.append(cancel) }
        }
        let params: JSONValue = .object(["op": .string("cloud.machine.list"), "params": .object([:])])
        _ = store.apply(.unknown(name: "apps-provider-request", payload: .object([
            "event": .string("apps-provider-request"), "request_id": .number(7), "app": .string("cmux/cloud"),
            "origin": .string("user"), "op": .string("credential.relay"), "params": params,
            "idempotency_key": .string("k"), "deadline_ms": .number(30_000),
        ])))
        _ = store.apply(.unknown(name: "apps-provider-cancel", payload: .object([
            "event": .string("apps-provider-cancel"), "request_id": .number(7), "reason": .string("timeout"),
        ])))
        #expect(calls == [AppsProviderCall(requestID: 7, app: "cmux/cloud", origin: "user", op: "credential.relay", params: params,
                                           idempotencyKey: "k", deadlineMs: 30_000)])
        #expect(cancels == [AppsProviderCancel(requestID: 7, reason: "timeout")])
    }
}
