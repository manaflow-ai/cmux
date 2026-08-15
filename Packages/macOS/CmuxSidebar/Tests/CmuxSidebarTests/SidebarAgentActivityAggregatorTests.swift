import Testing

@testable import CmuxSidebar

@Suite("Sidebar agent activity aggregator")
struct SidebarAgentActivityAggregatorTests {
    @Test func countsOneStatePerPanel() {
        let counts = SidebarAgentActivityAggregator().counts(panelActivities: [
            .running,
            .needsInput,
            .inactive,
        ])

        #expect(counts == .init(running: 1, needsInput: 1))
    }

    @Test func combinesWorkspaceCounts() {
        let counts = SidebarAgentActivityAggregator().total(counts: [
            SidebarAgentActivityCounts(running: 2),
            SidebarAgentActivityCounts(running: 1, needsInput: 3),
        ])

        #expect(counts == .init(running: 3, needsInput: 3))
    }
}
