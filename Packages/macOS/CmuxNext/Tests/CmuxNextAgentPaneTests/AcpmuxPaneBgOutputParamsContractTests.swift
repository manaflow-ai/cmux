import Foundation
import Testing
@testable import CmuxNextAgentPane

/// Every `_acpmux/bg/output` the agent page sends, from `schemas/agent-pane/bg-output-params.json`
/// (cmux-agent-pane-policy `tests/typescript.rs` holds direct.ts to that file), run through the
/// relay's params rule. A "Background task finished: bg-…" line opens to the task's last bytes
/// (direct.ts `bgTail`, `maxBytes`, cmux#48648); the rule knew only `fromByte`, so the host refused
/// every such open as `transport.intent_invalid`.
@Suite
struct AcpmuxPaneBgOutputParamsContractTests {
    static func contract() throws -> [[String: Any]] {
        var root = URL(fileURLWithPath: #filePath)
        let path = "schemas/agent-pane/bg-output-params.json"
        while !FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path) {
            let parent = root.deletingLastPathComponent()
            try #require(parent.path != root.path, "no \(path) above \(#filePath)")
            root = parent
        }
        let data = try Data(contentsOf: root.appendingPathComponent(path))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try #require(object["output"] as? [[String: Any]])
    }

    private static func frame(_ params: [String: Any]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": 1, "method": "_acpmux/bg/output", "params": params]
    }

    @Test func everyBgOutputThePageSendsPassesTheParamsRule() throws {
        let frames = try Self.contract()
        #expect(frames.count >= 2)
        for entry in frames {
            let name = entry["name"] as? String ?? "?"
            let params = try #require(entry["params"] as? [String: Any], "\(name) has no params")
            #expect(!AcpmuxPaneMethods.breaksParamsRule(Self.frame(params), modeFields: nil),
                    "the relay refuses the page's \(name) bg/output: add its keys to knownParams[\"_acpmux/bg/output\"]")
        }
    }

    @Test func theFinishedLinesTailIsInTheContract() throws {
        let tail = try #require(try Self.contract().first { $0["name"] as? String == "tail" }?["params"] as? [String: Any])
        #expect(tail["maxBytes"] is Int)
        #expect(!AcpmuxPaneMethods.breaksParamsRule(Self.frame(tail), modeFields: nil))
    }

    @Test func aKeyThePageDoesNotSendIsStillRefused() throws {
        var tail = try #require(try Self.contract().first { $0["name"] as? String == "tail" }?["params"] as? [String: Any])
        tail["path"] = "/etc/passwd"
        #expect(AcpmuxPaneMethods.breaksParamsRule(Self.frame(tail), modeFields: nil))
    }
}
