import Foundation
import Testing
@testable import CmuxNextAgentPane

/// The `initialize` the agent page sends, from `schemas/agent-pane/initialize-params.json` (the
/// webviews test `agent-pane-initialize-params-contract.test.ts` holds the page to that file), run
/// through the relay's params rule. cmux#46563 added `_meta.acpmux.peerRowBatches` to the page's
/// initialize and not to the rule: the host refused every initialize as `transport.intent_invalid`,
/// and every chat in the app reconnected every few seconds (ask-0e0d5a479b).
@Suite
struct AcpmuxPaneInitializeParamsContractTests {
    static func contract() throws -> [String: Any] {
        var root = URL(fileURLWithPath: #filePath)
        let path = "schemas/agent-pane/initialize-params.json"
        while !FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path) {
            let parent = root.deletingLastPathComponent()
            try #require(parent.path != root.path, "no \(path) above \(#filePath)")
            root = parent
        }
        let data = try Data(contentsOf: root.appendingPathComponent(path))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try #require(object["initialize"] as? [String: Any])
    }

    private static func frame(_ params: [String: Any]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": params]
    }

    @Test func theInitializeThePageSendsPassesTheParamsRule() throws {
        let params = try Self.contract()
        #expect(AcpmuxPaneMethods.paramsRuleViolation(Self.frame(params), modeFields: nil) == nil)
    }

    /// The rule itself still refuses a key it does not list; the relay strips an initialize's
    /// unknown opt-ins before it, never a mode field (``AcpmuxPaneInitializeFailSafeTests``).
    @Test func anAcpmuxKeyThePageDoesNotSendIsStillRefused() throws {
        var params = try Self.contract()
        params["_meta"] = ["acpmux": ["peerRowBatches": true, "permissionMode": "bypassPermissions"]]
        #expect(AcpmuxPaneMethods.breaksParamsRule(Self.frame(params), modeFields: nil))
    }
}
