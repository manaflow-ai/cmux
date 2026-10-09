import AppKit
import CmuxNextDesign
import Testing
@testable import CmuxNextTabs

/// cx-kxa2: a tab's status badge (needs input, done, failed) draws the
/// chosen status icon set; the default set keeps today's colored dot.
@MainActor @Suite struct TabStatusBadgeIconSetTests {
    func cell(_ status: TabStatus, kind: StatusBlockedKind? = nil) -> TabCell {
        var item = TabItem(id: TabID("t"), title: "Agent", status: status)
        item.blockedKind = kind
        return TabCell(item: item)
    }

    @Test func theDefaultSetKeepsTheDot() {
        let config = StatusIndicatorConfig()
        for status in [TabStatus.needsInput, .success, .failure, .none] {
            #expect(cell(status).statusBadgePlan(config: config) == nil, "\(status)")
        }
    }

    @Test func aCandidateSetDrawsTheBadgeStateWithItsKind() throws {
        let config = StatusIndicatorConfig(iconSet: .badges)
        let question = try #require(cell(.needsInput, kind: .question).statusBadgePlan(config: config))
        #expect(question == StatusIndicatorPlan.make(.waiting(kind: .question), style: .arc, animates: false, set: .badges))
        let auth = try #require(cell(.needsInput, kind: .auth).statusBadgePlan(config: config))
        #expect(auth != question)
        #expect(cell(.success).statusBadgePlan(config: config) == StatusIndicatorPlan.make(.success, style: .arc, animates: false, set: .badges))
        #expect(cell(.failure).statusBadgePlan(config: config) == StatusIndicatorPlan.make(.error, style: .arc, animates: false, set: .badges))
        #expect(cell(.none).statusBadgePlan(config: config) == nil, "an unread dot is not a status")
    }
}
