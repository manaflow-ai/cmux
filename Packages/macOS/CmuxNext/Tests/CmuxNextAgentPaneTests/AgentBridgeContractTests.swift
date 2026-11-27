@testable import CmuxNextAgentPane
import Foundation
import Testing

/// The agent page's calls to the app, checked against the one contract both sides share,
/// `schemas/agent-bridge/contract.json`. The webviews test (`agentBridgeContract.test.ts`) fails when
/// the page sends a method or key that is not there. This suite fails when the app's own tables
/// (``AgentPageOps``, the per-method params) or its old bridge's decoder drift from it. `account.add`
/// was decoded by the old bridge and sent by the page, but missing from ``AgentPageOps``, so Add
/// account failed `cmux.protocol.unknown_op` on the shared page host.
@Suite struct AgentBridgeContractTests {
    static func repoRoot() throws -> URL {
        var root = URL(fileURLWithPath: #filePath)
        while !FileManager.default.fileExists(atPath: root.appendingPathComponent("schemas/agent-bridge/contract.json").path) {
            let parent = root.deletingLastPathComponent()
            try #require(parent.path != root.path, "no schemas/agent-bridge/contract.json above \(#filePath)")
            root = parent
        }
        return root
    }

    static func contract() throws -> [String: Any] {
        let data = try Data(contentsOf: try repoRoot().appendingPathComponent("schemas/agent-bridge/contract.json"))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// The contract as one line per entry, for a failure message that says what to paste.
    static func lines(_ table: [String: String]) -> String {
        table.keys.sorted().map { "    \"\($0)\": \"\(table[$0]!)\"," }.joined(separator: "\n")
    }

    @Test func theOpsAreTheAppsOps() throws {
        let listed = try #require(try Self.contract()["ops"] as? [String: String])
        let missing = AgentPageOps.methods.filter { listed[$0.key] != $0.value }
        let extra = listed.filter { AgentPageOps.methods[$0.key] != $0.value }
        #expect(missing.isEmpty, "add to schemas/agent-bridge/contract.json ops:\n\(Self.lines(missing))")
        #expect(extra.isEmpty, "remove from schemas/agent-bridge/contract.json ops (the app has no such op):\n\(Self.lines(extra))")
    }

    @Test func theParamsAreTheAppsParams() throws {
        let listed = try #require(try Self.contract()["params"] as? [String: [String]])
        let app = AgentPaneReplyRequest.knownParams.merging(AgentPaneEnvironmentRequest.knownParams) { first, _ in first }
        #expect(Set(listed.keys) == Set(app.keys), "params methods differ: app \(app.keys.sorted()), contract \(listed.keys.sorted())")
        for (method, keys) in app {
            #expect(Set(listed[method] ?? []) == keys, "\(method): app takes \(keys.sorted()), contract lists \(listed[method] ?? [])")
        }
    }

    /// Every method the old bridge decodes is an op too, or is listed as the old bridge's alone.
    @Test func everyDecodedMethodIsAnOpOrLegacyOnly() throws {
        let contract = try Self.contract()
        let legacy = Set((contract["legacyOnly"] as? [String: String] ?? [:]).keys)
        let source = try String(contentsOf: try Self.repoRoot()
            .appendingPathComponent("Packages/macOS/CmuxNext/Sources/CmuxNextAgentPane/AgentPaneRequest+Decoding.swift"), encoding: .utf8)
        let code = source.split(separator: "\n").map { line in line.range(of: "//").map { String(line[..<$0.lowerBound]) } ?? String(line) }
            .joined(separator: "\n")
        let cases = try Regex(#"\bcase\s+((?:"[^"]+"\s*,\s*)*"[^"]+")\s*(?:where[^:]*)?:"#)
        let literal = try Regex(#""([^"]+)""#)
        var decoded = Set<String>()
        for match in code.matches(of: cases) {
            let group = String(code[match.range])
            for name in group.matches(of: literal) { decoded.insert(String(group[name.range]).trimmingCharacters(in: CharacterSet(charactersIn: "\""))) }
        }
        #expect(decoded.count > 100, "found only \(decoded.count) decoder cases; did the decoder move?")
        let methods = Set(AgentPageOps.methods.values)
        let stray = decoded.subtracting(methods).subtracting(legacy)
        #expect(stray.isEmpty, "the old bridge decodes these, but the page host has no op for them; add them to AgentPageOps (and the contract), or list them in legacyOnly: \(stray.sorted())")
        #expect(legacy.isDisjoint(with: methods), "legacyOnly lists methods the page host serves: \(legacy.intersection(methods).sorted())")
    }

    /// A method the page sends that no app serves stays listed only until the app serves it.
    @Test func unservedMethodsAreNotServed() throws {
        let unserved = Set((try Self.contract()["unserved"] as? [String: String] ?? [:]).keys)
        let served = unserved.intersection(AgentPageOps.methods.values)
        #expect(served.isEmpty, "the app serves these now; remove them from the contract's unserved: \(served.sorted())")
    }
}
