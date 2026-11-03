import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextCloud
import Foundation
import Testing

/// The network and firewall actions take an id (or a rule) in `--path`; a
/// missing one said "Pass an absolute Cloud file path without '..'.", the
/// file actions' refusal. Each now names its id, its flag and where to find one.
@MainActor
struct CloudNetworkHintsTests {
    static var hints: [(ActionID, String)] {
        [
            ("cloudTunnelAttach", CloudStrings.networkIDRequired), ("cloudTunnelDetach", CloudStrings.networkIDRequired),
            ("cloudFirewallGet", CloudStrings.ruleIDRequired), ("cloudFirewallDelete", CloudStrings.ruleIDRequired),
            ("cloudFirewallCreate", CloudStrings.ruleJSONRequired),
        ]
    }

    @Test func aMissingIDNamesItsFlagAndListVerb() throws {
        for (id, hint) in Self.hints { try check(id, hint) }
    }

    private func check(_ id: ActionID, _ hint: String) throws {
        let descriptor = try #require(ActionCatalog.all.first { $0.id == id })
        #expect(descriptor.arguments.contains { $0.name == "path" }, "\(id) takes --path")
        #expect(hint.contains("--path"))
        #expect(hint != CloudStrings.filePathRequired)
        let verbs = CloudHintCommandsTestsSupport.verbs(in: hint)
        for verb in verbs {
            #expect(ActionCatalog.all.first { $0.cliName == "cloud \(verb)" }?.cli == true, "`cmux cloud \(verb)` is not a CLI verb")
        }
    }

    @Test func theRefusalComesFromTheIDArgument() throws {
        #expect(throws: ActionFailure(message: CloudStrings.ruleIDRequired)) {
            try CloudHandlers.idArgument(ActionInvocation(arguments: ["path": .string("  ")]), CloudStrings.ruleIDRequired)
        }
        #expect(try CloudHandlers.idArgument(ActionInvocation(arguments: ["path": .string(" net-1 ")]), CloudStrings.networkIDRequired) == "net-1")
    }

    /// The example in the create refusal is a rule the handler accepts.
    @Test func theRuleExampleDecodes() throws {
        let hint = CloudStrings.ruleJSONRequired
        let start = try #require(hint.range(of: "'{")).lowerBound, end = try #require(hint.range(of: "}'", options: .backwards)).upperBound
        let json = String(hint[hint.index(after: start)..<hint.index(before: end)])
        let value = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        for side in ["source", "destination"] {
            let data = try JSONSerialization.data(withJSONObject: value[side] ?? [:])
            _ = try JSONDecoder().decode(CloudFirewallEndpoint.self, from: data)
        }
    }
}

/// `cmux cloud <verb>` occurrences in a hint.
enum CloudHintCommandsTestsSupport {
    static func verbs(in text: String) -> [String] {
        let pattern = try? NSRegularExpression(pattern: "cmux cloud ([a-z-]+)")
        let range = NSRange(text.startIndex..., in: text)
        return (pattern?.matches(in: text, range: range) ?? []).compactMap { Range($0.range(at: 1), in: text).map { String(text[$0]) } }
    }
}
