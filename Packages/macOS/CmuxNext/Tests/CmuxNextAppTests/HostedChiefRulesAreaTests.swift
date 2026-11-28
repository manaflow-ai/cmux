import CmuxNextHomeEngine
import Foundation
import Testing
@testable import CmuxNextHostedChief

/// https://github.com/manaflow-ai/cmux/pull/59517 moved the Hosted Chief's rules to cmux-home-rules, which names every op
/// `area.name` (`cloud.chiefs_tab`); the Swift side sent bare names (`chiefs_tab`), every one answered `unknownOp`,
/// and a Debug build stopped at launch in `ChiefRules.rule` (found verifying cmux issue 59902).
struct HostedChiefRulesAreaTests {
    @Test func theRulesReachTheirRustArea() throws {
        let value = try HomeCloudChiefs.okValue(["value": 7])
        #expect(value as? Int == 7)
    }
}
