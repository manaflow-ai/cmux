import CmuxNextAgentPane
import CmuxNextDaemon
import CmuxNextSettings
import Testing

struct FeedEventDeliveryTests {
    @Test func anInAppEventStaysLocalWhenTheFeedResumes() {
        let prefs = CmuxConfigSnapshot.parse(["notifications": ["delivery": ["finished": "inApp"]]],
                                             validDensities: [], validMetrics: []).notifications
        let policy = FeedHandoffPolicy(preferences: prefs, mutedWorkspaces: [])
        var item = FeedLocalItem(id: "1", dedupeKey: "turn", title: "Finished", createdAtMs: 0)
        #expect(policy.content(for: item) == nil)
        #expect(policy.frozenContent(for: item) == nil)
        item.level = "warning"
        #expect(policy.content(for: item) != nil)
        #expect(policy.frozenContent(for: item) != nil)
    }
}
