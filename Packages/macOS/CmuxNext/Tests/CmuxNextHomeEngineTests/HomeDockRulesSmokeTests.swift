import CmuxHomeCore
@testable import CmuxNextHomeEngine
import Testing

/// The dock's rules are the Rust `dock.*` ops (cmux-home-rules, tested there). This smoke test
/// crosses the FFI through the Swift callers once: a plan, a reason and a link check.
@MainActor
struct HomeDockRulesSmokeTests {
    @Test func theDockRulesAnswerThroughTheFFI() {
        let chief = ConversationID("conv_default")
        let plan = HomeChiefActionPlan(front: .none, chiefs: [.init(conversation: chief, isWorking: true, isDefault: true)])
        #expect(plan.stop == .chief(chief))
        #expect(plan.settings == .open(chief))
        #expect(HomeChiefActionPlan(front: .none, chiefs: []).settings == .noChief)
        #expect(dockRule("dock.opens_link", ["scheme": "https"], fallback: false))
        #expect(!dockRule("dock.opens_link", ["scheme": "file"], fallback: true))
    }
}
