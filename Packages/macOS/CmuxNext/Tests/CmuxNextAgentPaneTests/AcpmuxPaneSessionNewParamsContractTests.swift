import Foundation
import Testing
@testable import CmuxNextAgentPane

/// Every `session/new` the agent page sends, from `schemas/agent-pane/session-new-params.json` (the
/// webviews test `agent-pane-session-new-params-contract.test.ts` holds the page to that file), run
/// through the relay's params rule. The attach had this contract after its `settled` and `hold` keys
/// failed every chat open (cmux#42185, cmux#42460); the start frame did not, so a key the page added
/// there would fail every chat's start the same way (the 2026-11-12 outage, cmux#44964).
@Suite
struct AcpmuxPaneSessionNewParamsContractTests {
    static func contract() throws -> [[String: Any]] {
        var root = URL(fileURLWithPath: #filePath)
        let path = "schemas/agent-pane/session-new-params.json"
        while !FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path) {
            let parent = root.deletingLastPathComponent()
            try #require(parent.path != root.path, "no \(path) above \(#filePath)")
            root = parent
        }
        let data = try Data(contentsOf: root.appendingPathComponent(path))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try #require(object["new"] as? [[String: Any]])
    }

    private static func frame(_ params: [String: Any]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": 1, "method": "session/new", "params": params]
    }

    @Test func everyStartThePageSendsPassesTheParamsRule() throws {
        let starts = try Self.contract()
        #expect(starts.count >= 5)
        for start in starts {
            let name = start["name"] as? String ?? "?"
            let params = try #require(start["params"] as? [String: Any], "\(name) has no params")
            let violation = AcpmuxPaneMethods.paramsRuleViolation(Self.frame(params), modeFields: ["permissionMode"])
            #expect(violation == nil, "the relay refuses the page's \(name) start (\(violation ?? "")): add its keys to knownParams[\"session/new\"]")
        }
    }

    @Test func aStartKeyThePageDoesNotSendIsStillRefused() throws {
        var start = try #require(try Self.contract().first?["params"] as? [String: Any])
        start["permissionMode"] = "bypassPermissions"
        #expect(AcpmuxPaneMethods.breaksParamsRule(Self.frame(start), modeFields: nil))
    }
}
