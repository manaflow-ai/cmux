import Foundation
import Testing
@testable import CmuxNextAgentPane

/// Every method the relay takes from the agent page, against `schemas/agent-pane/methods.json` (the
/// webviews test `agent-pane-method-contracts.test.ts` fails when the page sends a method or a key
/// that file lacks). The relay refuses a method outside ``AcpmuxPaneMethods/requests`` and a key
/// outside ``AcpmuxPaneMethods/knownParams`` as `transport.intent_invalid`; cmux#46563 sent
/// `_meta.acpmux.peerRowBatches` on initialize with no rule here, and every chat in the app
/// reconnected about 490 times an hour (cmux#49148, ask-0e0d5a479b; RFD 0028).
@Suite
struct AcpmuxPaneMethodContractsTests {
    struct Contract {
        var methods: [String: (params: Set<String>, acpmux: Set<String>)]
        var notRelayed: Set<String>
        var refusedToday: Set<String>
    }

    static func contract() throws -> Contract {
        var root = URL(fileURLWithPath: #filePath)
        let path = "schemas/agent-pane/methods.json"
        while !FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path) {
            let parent = root.deletingLastPathComponent()
            try #require(parent.path != root.path, "no \(path) above \(#filePath)")
            root = parent
        }
        let data = try Data(contentsOf: root.appendingPathComponent(path))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let methods = try #require(object["methods"] as? [String: [String: Any]])
        var out: [String: (params: Set<String>, acpmux: Set<String>)] = [:]
        for (name, entry) in methods {
            out[name] = (Set(entry["params"] as? [String] ?? []), Set(entry["acpmux"] as? [String] ?? []))
        }
        let notRelayed = Set((object["not_relayed"] as? [String: Any] ?? [:]).keys)
        let refusedToday = Set((object["refused_today"] as? [String: Any] ?? [:]).keys)
        return Contract(methods: out, notRelayed: notRelayed, refusedToday: refusedToday)
    }

    @Test func everyMethodTheRelayTakesHasAContract() throws {
        let contract = try Self.contract()
        let taken = AcpmuxPaneMethods.requests
            .union(AcpmuxPaneMethods.notifications)
            .union([AcpmuxPaneMethods.initialize])
        #expect(taken.subtracting(contract.methods.keys).sorted() == [])
        #expect(Set(contract.methods.keys).subtracting(taken).sorted() == [])
    }

    @Test func theParamsRuleIsTheContract() throws {
        let contract = try Self.contract()
        #expect(Set(AcpmuxPaneMethods.knownParams.keys) == Set(contract.methods.keys))
        for (method, known) in AcpmuxPaneMethods.knownParams {
            let listed = contract.methods[method]
            #expect(listed?.params == known.params, "\(method) params")
            #expect(listed?.acpmux == known.acpmux, "\(method) _meta.acpmux")
        }
    }

    /// A method the contract says the relay refuses today is still refused (it moves to `methods`
    /// when the relay takes it), and one sent only off the relay is not taken.
    @Test func theExceptionsAreNotRelayed() throws {
        let contract = try Self.contract()
        #expect(contract.refusedToday.intersection(AcpmuxPaneMethods.requests).sorted() == [])
        #expect(contract.notRelayed.intersection(AcpmuxPaneMethods.requests).sorted() == [])
    }

    /// Each method's own params, all present at once, pass the params rule; a key the contract does
    /// not list is still refused.
    @Test func everyContractKeyPassesTheRuleAndNoOtherDoes() throws {
        let contract = try Self.contract()
        for (method, listed) in contract.methods where !listed.params.contains("_meta") {
            let params = Dictionary(uniqueKeysWithValues: listed.params.map { ($0, "x" as Any) })
            let frame: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": method, "params": params]
            let violation = AcpmuxPaneMethods.paramsRuleViolation(frame, modeFields: nil)
            #expect(violation == nil, "\(method): \(violation ?? "")")
            var extra = params
            extra["notAContractKey"] = "x"
            let refused: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": method, "params": extra]
            #expect(AcpmuxPaneMethods.breaksParamsRule(refused, modeFields: nil), "\(method) takes an unlisted key")
        }
    }
}
