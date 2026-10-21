import Foundation
import Testing
@testable import CmuxNextMobile

/// The Swift mirror of cmux-mobile-host's workspace group rules (policy.rs
/// `group_params`, cmux-next-ios/SECURITY.md "Workspace groups").
struct DaemonLanePolicyGroupTests {
    let policy = DaemonLanePolicy(deviceID: "phone")

    private func line(_ object: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func resource(_ operation: String, _ extra: [String: Any], key: String? = "cmux-next-ios-group-1",
                          current: Bool = true) -> Data {
        var params = extra
        if current {
            params["machine"] = "current"
            params["session"] = "current"
        }
        var object: [String: Any] = ["protocol": "cmux.protocol/2", "type": "request", "id": "r7", "operation": operation, "params": params]
        if let key { object["idempotency_key"] = key }
        return line(object)
    }

    private func params(_ request: Data) -> [String: Any] {
        ((try? JSONSerialization.jsonObject(with: request) as? [String: Any])?["params"] as? [String: Any]) ?? [:]
    }

    /// The shapes the iOS app sends pass the value checks; a new group is sent on
    /// as checked, and the edits that name a group or a workspace wait for
    /// cmux-mobile-host's ownership check (refused on this lane).
    @Test func allowedShapesPass() {
        let create = resource("workspace_group.create", ["name": "Release", "color": "red", "room": "default"])
        guard case .rewrite(let sent) = policy.evaluate(create) else { Issue.record("refused a new group"); return }
        #expect(sent == create)
        for (operation, extra) in [
            ("workspace_group.update", ["workspace_group": "grp_0a1b", "name": "Ship"]),
            ("workspace_group.update", ["workspace_group": "grp_0a1b", "color": "cyan"]),
            ("workspace_group.update", ["workspace_group": "grp_0a1b", "collapsed": true]),
            ("workspace_group.delete", ["workspace_group": "grp_0a1b"]),
            ("workspace.place", ["workspace": "ws_01HZY", "group": "grp_0a1b"]),
            ("workspace.place", ["workspace": "ws_01HZY", "group": NSNull()]),
        ] as [(String, [String: Any])] {
            let request = resource(operation, extra)
            #expect(DaemonLanePolicy.groupRefusal(operation, params(request)) == nil, "\(operation) \(extra)")
            guard case .refuse(let answer) = policy.evaluate(request) else {
                Issue.record("forwarded \(operation) without an ownership check")
                continue
            }
            let object = try? JSONSerialization.jsonObject(with: answer) as? [String: Any]
            #expect(object?["type"] as? String == "response")
        }
    }

    @Test func otherShapesAreRefused() {
        for (operation, extra) in [
            ("workspace_group.list", [:]),
            ("workspace_group.move", ["workspace_group": "g", "index": 0]),
            ("workspace.placement.list", [:]),
            ("room.create", ["name": "x"]),
            ("room.pin", ["workspace": "ws_1", "room": "default"]),
            ("workspace_group.create", ["name": "a", "index": 0]),
            ("workspace_group.create", ["name": "a", "collapsed": true]),
            ("workspace_group.create", ["name": "a", "icon": "star"]),
            ("workspace_group.create", ["name": "a", "command": "id"]),
            ("workspace_group.create", ["name": "a", "argv": ["sh"]]),
            ("workspace_group.create", ["name": "a", "env": ["BASH_ENV": "/tmp/x"]]),
            ("workspace_group.update", ["workspace_group": "g", "room": "other"]),
            ("workspace_group.update", ["workspace_group": "g", "top_index": 0]),
            ("workspace_group.update", ["workspace_group": "g", "pinned": true]),
            ("workspace.place", ["workspace": "ws_1", "group": "g", "index": 2]),
            ("workspace.place", ["workspace": "ws_1", "group": "g", "cwd": "/"]),
            ("workspace_group.create", [:]),
            ("workspace_group.create", ["name": "  "]),
            ("workspace_group.create", ["name": "a\nb"]),
            ("workspace_group.create", ["name": String(repeating: "x", count: 257)]),
            ("workspace_group.create", ["name": 7]),
            ("workspace_group.create", ["name": "a", "color": "#ff0000"]),
            ("workspace_group.create", ["name": "a", "color": "chartreuse"]),
            ("workspace_group.create", ["name": "a", "room": "a room"]),
            ("workspace_group.update", ["name": "a"]),
            ("workspace_group.update", ["workspace_group": "g"]),
            ("workspace_group.update", ["workspace_group": "g", "collapsed": "yes"]),
            ("workspace_group.update", ["workspace_group": "g", "collapsed": 1]),
            ("workspace_group.update", ["workspace_group": "g", "color": NSNull()]),
            ("workspace_group.delete", [:]),
            ("workspace_group.delete", ["workspace_group": "../g"]),
            ("workspace.place", ["workspace": "ws_1"]),
            ("workspace.place", ["group": "g"]),
            ("workspace.place", ["workspace": "current", "group": "g"]),
            ("workspace.place", ["workspace": 3, "group": "g"]),
            ("workspace.place", ["workspace": "ws_1", "group": 3]),
        ] as [(String, [String: Any])] {
            let request = resource(operation, extra)
            guard case .refuse(let answer) = policy.evaluate(request) else {
                Issue.record("forwarded \(operation) \(extra)")
                continue
            }
            let object = try? JSONSerialization.jsonObject(with: answer) as? [String: Any]
            #expect(object?["ok"] as? Bool == false)
            if DaemonLanePolicy.allowedResourceOperations[operation].map({ Set(extra.keys).isSubset(of: $0) }) == true {
                #expect(DaemonLanePolicy.groupRefusal(operation, extra) != nil, "\(operation) \(extra)")
            }
        }
        // Another machine or session, or no idempotency key.
        for request in [
            resource("workspace_group.create", ["name": "a", "machine": "other"], current: false),
            resource("workspace_group.create", ["name": "a", "session": "s2"], current: false),
            resource("workspace_group.create", ["name": "a"], key: nil),
        ] {
            guard case .refuse = policy.evaluate(request) else {
                Issue.record("forwarded \(String(decoding: request, as: UTF8.self))")
                continue
            }
        }
    }
}
