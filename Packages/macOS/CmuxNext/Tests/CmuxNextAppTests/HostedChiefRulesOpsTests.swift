@testable import CmuxNextHomeModel
@testable import CmuxNextHostedChief
import Testing

/// Every op the Hosted Chief's rules call is one the linked cmux-app-ffi answers, by the
/// `AREA.NAME` path `cmux_home_call` takes. A bare `chiefs_tab` was `unknownOp` on every build
/// (debug builds stopped at launch, release builds took every fallback): cmux#60364's capture,
/// 2026-11-28.
struct HostedChiefRulesOpsTests {
    @Test func everyChiefRuleOpIsInTheLinkedOpsList() throws {
        let names: Set<String> = Set(try HomeRules.call("ops.list", HomeRules.Empty()) as [String])
        for op in ChiefRules.Op.allCases {
            #expect(names.contains(op.path), "\(op.path) is not an op of the linked cmux-app-ffi")
        }
    }

    @Test func theChiefTabRuleRunsWithoutItsFallback() throws {
        // chiefs_tab with no cloud Chief and no local conversation answers no conversation;
        // the point is that the op runs (an unknown op throws).
        let tab = ChiefRules.Tab(chiefs: HomeCloudChiefs(), local: "conv_local", localHasHistory: true,
                                 choice: .hosted, prefersLocal: true)
        let reply: ChiefRules.Conversation = try ChiefRules.call(.chiefsTab, tab)
        #expect(reply.conversation == "conv_local")
    }
}
