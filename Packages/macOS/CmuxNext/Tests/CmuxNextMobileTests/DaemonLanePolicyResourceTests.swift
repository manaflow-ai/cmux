import Foundation
import Testing
@testable import CmuxNextMobile

/// The Swift mirror of cmux-mobile-host's daemon lane (policy.rs): Clear All
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
            resource("notification.clear", current, key: "cmux-next-ios-notification-clear-1"),
            resource("sidebar_layout.get", current),
        ] {
            guard case .rewrite(let sent) = policy.evaluate(request) else {
                Issue.record("refused \(String(decoding: request, as: UTF8.self))")
                continue
            }
            #expect(sent == request)
        }
    }

    /// This lane cannot read the Mac's layout or tree to confirm the phone's object,
    /// so Unpin and the sidebar order stay refused here (cmux-mobile-host checks them).
    @Test func ownershipLinesAreRefusedOnThisLane() {
        let unpin = resource("sidebar_layout.update", current.merging(["op": ["kind": "item.remove", "id": "itm_abcdefgh234567ab"]]) { a, _ in a },
                             key: "cmux-next-ios-unpin-1")
        guard case .refuse = policy.evaluate(unpin) else { Issue.record("forwarded an unpin"); return }
        guard case .refuse = policy.evaluate(line(["cmd": "set-personal-workspace", "id": "m2", "session_id": "reg",
                                                   "workspace_key": "k", "index": 3])) else {
            Issue.record("forwarded set-personal-workspace")
            return
        }
    }

    /// A duplicate key reaches the daemon only as the one value this policy checked.
    @Test func duplicateKeysAreSentAsChecked() {
        let raw = Data(#"{"protocol":"cmux.protocol/2","type":"request","id":"r1","operation":"pane.run","operation":"sidebar_layout.get","params":{"machine":"current","session":"current"}}"#.utf8)
        switch policy.evaluate(raw) {
        case .rewrite(let sent):
            let text = String(decoding: sent, as: UTF8.self)
            #expect(text.components(separatedBy: "\"operation\"").count == 2)
            #expect(!text.contains("pane.run"))
        case .refuse: break
        case .forward: Issue.record("a duplicate key was forwarded as sent")
        }
    }

    @Test func indexIsAnIntegerPlace() {
        #expect(DaemonLanePolicy.isPlace(3))
        #expect(DaemonLanePolicy.isPlace(0))
        for bad: Any in [3.0, -1, true, UInt64.max, "3"] {
            #expect(!DaemonLanePolicy.isPlace(bad), "\(bad)")
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
        for extra: [String: Any] in [["remote_localhost": true], ["group": "g"], ["theme": "x"], ["browser_profile_id": "p"], ["index": -1], ["index": 3.5]] {
            var object: [String: Any] = ["cmd": "set-personal-workspace", "id": 1, "session_id": "s", "workspace_key": "k"]
            object.merge(extra) { _, b in b }
            guard case .refuse = policy.evaluate(line(object)) else {
                Issue.record("forwarded \(extra)")
                continue
            }
        }
    }
}
