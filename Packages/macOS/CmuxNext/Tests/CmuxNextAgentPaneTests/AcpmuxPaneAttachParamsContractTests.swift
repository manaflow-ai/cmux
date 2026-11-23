import Foundation
import Testing
@testable import CmuxNextAgentPane

/// Every `_acpmux/attach` the agent page sends, from `schemas/agent-pane/attach-params.json` (the
/// webviews test `agent-pane-attach-params-contract.test.ts` holds the page to that file), run
/// through the relay's params rule. A chat drawn from the row store attaches with `hold: true`
/// (rows/holdKinds.ts); the rule did not know `hold`, so the host refused that attach as
/// `transport.intent_invalid`, the open failed and a chat typed on the New Tab page never started
/// ("Couldn't start Claude Code (sr2 internal): Something went wrong, so that didn't go through.",
/// cmux#42460). `settled` broke the same way before (cmux#42185).
@Suite
struct AcpmuxPaneAttachParamsContractTests {
    static func contract() throws -> [[String: Any]] {
        var root = URL(fileURLWithPath: #filePath)
        let path = "schemas/agent-pane/attach-params.json"
        while !FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path) {
            let parent = root.deletingLastPathComponent()
            try #require(parent.path != root.path, "no \(path) above \(#filePath)")
            root = parent
        }
        let data = try Data(contentsOf: root.appendingPathComponent(path))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try #require(object["attach"] as? [[String: Any]])
    }

    private static func frame(_ params: [String: Any]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": 1, "method": "_acpmux/attach", "params": params]
    }

    @Test func everyAttachThePageSendsPassesTheParamsRule() throws {
        let attaches = try Self.contract()
        #expect(attaches.count >= 5)
        for attach in attaches {
            let name = attach["name"] as? String ?? "?"
            let params = try #require(attach["params"] as? [String: Any], "\(name) has no params")
            #expect(!AcpmuxPaneMethods.breaksParamsRule(Self.frame(params), modeFields: nil),
                    "the relay refuses the page's \(name) attach: add its keys to knownParams[\"_acpmux/attach\"]")
        }
    }

    @Test func theRowStoreHoldIsInTheContract() throws {
        let hold = try #require(try Self.contract().first { $0["name"] as? String == "hold" }?["params"] as? [String: Any])
        #expect(hold["hold"] as? Bool == true)
        #expect(!AcpmuxPaneMethods.breaksParamsRule(Self.frame(hold), modeFields: nil))
    }

    /// A reconnect that holds the chat's rows asks only what it missed (`afterSeq`, cmux#47119). The rule did
    /// not know the key, so every such reconnect was refused as `transport.intent_invalid` and the pane said
    /// "cmux blocked opening this chat" over the composer (Leo, 2026-11-22: "frequently should not even
    /// appear in the first place").
    @Test func theReconnectsForwardAttachIsInTheContract() throws {
        let forward = try #require(try Self.contract().first { $0["name"] as? String == "forward, local" }?["params"] as? [String: Any])
        #expect(forward["afterSeq"] as? Int == 120)
        #expect(!AcpmuxPaneMethods.breaksParamsRule(Self.frame(forward), modeFields: nil))
    }

    @Test func aKeyThePageDoesNotSendIsStillRefused() throws {
        var hold = try #require(try Self.contract().first { $0["name"] as? String == "hold" }?["params"] as? [String: Any])
        hold["permissionMode"] = "bypassPermissions"
        #expect(AcpmuxPaneMethods.breaksParamsRule(Self.frame(hold), modeFields: nil))
    }
}
