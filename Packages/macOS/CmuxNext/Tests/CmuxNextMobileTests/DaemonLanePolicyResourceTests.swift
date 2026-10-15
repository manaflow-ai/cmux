import Foundation
import Testing
@testable import CmuxNextMobile

/// The Swift mirror of cnx-hostd's daemon lane (policy.rs): Clear All
/// Notifications, the person's pins and their sidebar order.
struct DaemonLanePolicyResourceTests {
    let policy = DaemonLanePolicy(deviceID: "phone")

    private func line(_ object: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func resource(_ operation: String, _ params: [String: Any], key: String? = nil) -> Data {
        var object: [String: Any] = ["protocol": "cmux.protocol/2", "type": "request", "id": "r7", "operation": operation, "params": params]
        if let key { object["idempotency_key"] = key }
        return line(object)
    }

    private let current: [String: Any] = ["machine": "current", "session": "current"]

    @Test func allowsTheWorkspaceResourceOps() {
        for request in [
            resource("notification.clear", current, key: "cnx-ios-notification-clear-1"),
            resource("sidebar_layout.get", current),
            resource("sidebar_layout.update", current.merging(["op": ["kind": "item.remove", "id": "itm_abcdefgh234567ab"]]) { a, _ in a },
                     key: "cnx-ios-unpin-1"),
        ] {
            guard case .rewrite(let sent) = policy.evaluate(request) else {
                Issue.record("refused \(String(decoding: request, as: UTF8.self))")
                continue
            }
            #expect(sent == request)
        }
    }

    @Test func refusesOtherResourceOpsAndParams() {
        for request in [
            resource("notification.list", current),
            resource("pane.run", current, key: "k"),
            resource("workspace.agent_folder.set", current, key: "k"),
            resource("notification.clear", ["machine": "other"], key: "k"),
            resource("notification.clear", current.merging(["terminal_id": "term_1"]) { a, _ in a }, key: "k"),
            resource("notification.clear", current),
            resource("sidebar_layout.update", ["op": ["kind": "layout.reset"]], key: "k"),
            resource("sidebar_layout.update", ["op": ["kind": "item.remove", "id": "itm_account"]], key: "k"),
            resource("sidebar_layout.update", ["op": ["kind": "item.remove", "id": "itm_abcdefgh234567ab", "x": 1]], key: "k"),
            line(["protocol": "cmux.protocol/2", "type": "request", "id": "r7", "operation": "notification.clear",
                  "params": current, "idempotency_key": "k", "origin": ["claim": "user"]]),
        ] {
            guard case .refuse(let answer) = policy.evaluate(request) else {
                Issue.record("forwarded \(String(decoding: request, as: UTF8.self))")
                continue
            }
            let object = try? JSONSerialization.jsonObject(with: answer) as? [String: Any]
            #expect(object?["ok"] as? Bool == false)
            #expect(object?["type"] as? String == "response")
        }
    }

    @Test func personalOrderIsAPlaceOnly() {
        #expect(policy.evaluate(line(["cmd": "list-personal", "id": "m1"])) == .forward)
        #expect(policy.evaluate(line(["cmd": "set-personal-workspace", "id": "m2", "session_id": "reg_01abc",
                                      "workspace_key": "0b8f6c2e-1d2a-4f00-9a7b-1c2d3e4f5a6b", "index": 3])) == .forward)
        for extra: [String: Any] in [["remote_localhost": true], ["group": "g"], ["theme": "x"], ["browser_profile_id": "p"], ["index": -1]] {
            var object: [String: Any] = ["cmd": "set-personal-workspace", "id": 1, "session_id": "s", "workspace_key": "k"]
            object.merge(extra) { _, b in b }
            guard case .refuse = policy.evaluate(line(object)) else {
                Issue.record("forwarded \(extra)")
                continue
            }
        }
    }
}
