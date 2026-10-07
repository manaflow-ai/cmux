import Foundation
import Testing
@testable import CmuxNextAgentActivity

@Suite("Agent activity timeline")
struct AgentActivityTimelineMergeTests {
    @Test("browser, CUA, and ACP events merge in time order")
    func mergeOrder() {
        let base = Date(timeIntervalSince1970: 10)
        let events = [
            AgentActivityTimelineEvent(id: "cua-2", agentID: "agent", source: .cua, at: base.addingTimeInterval(2), sequence: 2, title: "click"),
            AgentActivityTimelineEvent(id: "browser-1", agentID: "agent", source: .browser, at: base, sequence: 1, title: "navigate"),
            AgentActivityTimelineEvent(id: "acp-1", agentID: "agent", source: .acp, at: base.addingTimeInterval(1), sequence: 1, title: "tool_call"),
        ]

        let merged = AgentActivityTimelineMerger.merge(events)

        #expect(merged.map(\.id) == ["browser-1", "acp-1", "cua-2"])
    }
}
