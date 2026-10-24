import Foundation
import Testing
import WebKit
@testable import CmuxNextBrowserAutomation

/// The host's compiled domain policy (cmux-browser-host
/// `policy/webkit_rules.rs`) must be content rules WebKit accepts.
@MainActor
@Suite struct WebKitContentRulesTests {
    @Test func theHostsRuleShapeCompiles() async throws {
        let rules: DriverJSON = .array([
            .object(["trigger": .object(["url-filter": .string(".*")]), "action": .object(["type": .string("block")])]),
            .object(["trigger": .object(["url-filter": .string("^https://(www\\.)?example\\.com[:/?#]")]),
                     "action": .object(["type": .string("ignore-previous-rules")])]),
            .object(["trigger": .object(["url-filter": .string("^https://([^/?#@]*\\.)?cdn\\.test[:/?#]")]),
                     "action": .object(["type": .string("ignore-previous-rules")])]),
            .object(["trigger": .object(["url-filter": .string("^[a-z][a-z0-9+.-]*://[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+[:/?#]")]),
                     "action": .object(["type": .string("block")])]),
            .object(["trigger": .object(["url-filter": .string("^data:")]), "action": .object(["type": .string("ignore-previous-rules")])]),
        ])
        let list = try await WebKitContentRules.compile(identifier: "cmux-policy-test-\(UUID().uuidString)", rules: rules)
        #expect(!list.identifier.isEmpty)
    }

    @Test func aRuleWebKitCannotCompileIsInvalid() async {
        let rules: DriverJSON = .array([.object(["trigger": .object(["url-filter": .string("(a|b)")]),
                                                 "action": .object(["type": .string("block")])])])
        await #expect(throws: DriverError.self) {
            _ = try await WebKitContentRules.compile(identifier: "cmux-policy-bad-\(UUID().uuidString)", rules: rules)
        }
    }
}
