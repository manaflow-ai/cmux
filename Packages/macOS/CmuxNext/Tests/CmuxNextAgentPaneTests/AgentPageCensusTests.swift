@testable import CmuxNextAgentPane
import Testing

/// The liveness rule's arithmetic (`AgentPageLiveness`): every live agent page has a tab or an owner that bounds it,
/// and none its owner let go still draws. Two pages of Leo's NIGHTLY (2026-11-18) still reported visible with no tab.
struct AgentPageCensusTests {
    private typealias Page = AgentPageCensus.Page

    @Test func aHealthyAppBreaksNothing() {
        let census = AgentPageCensus(pages: [
            Page(role: .tab, visible: true, inWindow: true),
            Page(role: .tab, visible: false, inWindow: true),
            Page(role: .spare, visible: true, inWindow: true),
            Page(role: .kept, visible: true, inWindow: true),
            Page(role: .retiring, visible: false, inWindow: false),
            Page(role: .standalone, visible: true, inWindow: true),
        ])
        #expect(census.violations == 0)
        #expect(census.visibleTabless == 2, "the spare and the kept chat draw with no tab; the standalone panel is its caller's")
        #expect(census.count(.tab) == 2 && census.visible(.tab) == 1)
    }

    @Test func anOrphanBreaksTheRuleWhateverItsState() {
        for visible in [false, true] {
            let census = AgentPageCensus(pages: [Page(role: .orphan, visible: visible, inWindow: visible)])
            #expect(census.violations == 1, "an orphan (visible \(visible)) is never closed by anyone")
        }
    }

    @Test func aLetGoPageThatStillDrawsBreaksTheRule() {
        let census = AgentPageCensus(pages: [Page(role: .retiring, visible: true, inWindow: true)])
        #expect(census.violations == 1)
        #expect(census.visibleTabless == 1)
    }
}
