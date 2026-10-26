import CmuxNextPages
import CmuxNextPagesTestSupport
import Testing
@testable import CmuxNextAgentPane

/// The agent pages' WebKit warm-up (p08-startup-017): when its page may be made and when it goes,
/// and which engine a new agent page opens in, decided with no side effect.
@Suite struct AgentPageWarmupPlanTests {
    @Test func aWarmupQueuedPastTheSettleStillMakesItsPage() {
        var plan = AgentPageWarmupPlan()
        let settleDropped = plan.settle()
        #expect(!settleDropped, "no page yet: nothing goes")
        #expect(plan.start() == true, "the afterStartup warm-up still starts; its page goes once its load ends")
        #expect(plan.pageAlive)
        let loadDropped = plan.loadEnded()
        #expect(loadDropped, "the empty page goes, WebKit's setup and the pool stay")
        #expect(!plan.pageAlive)
    }

    @Test func aWarmupBeforeTheSettleKeepsItsPageUntilTheSettle() {
        var plan = AgentPageWarmupPlan()
        #expect(plan.start() == false, "made before the settle: kept for the first agent page")
        let loadDropped = plan.loadEnded()
        #expect(!loadDropped, "its load ending does not drop it before the settle")
        let settleDropped = plan.settle()
        #expect(settleDropped)
        #expect(!plan.pageAlive)
    }

    @Test func anAgentPageMadeFirstMeansNoWarmup() {
        var plan = AgentPageWarmupPlan()
        plan.agentPageMade()
        #expect(plan.start() == nil, "that page started WebKit")
        #expect(!plan.pageAlive)
    }

    @Test func anAgentPageLoadedDropsTheWarmupPage() {
        var plan = AgentPageWarmupPlan()
        _ = plan.start()
        let loadedDropped = plan.agentPageLoaded()
        #expect(loadedDropped)
        let settleDropped = plan.settle()
        #expect(!settleDropped, "already gone")
    }

    @Test func theWarmupStartsOncePerRun() {
        var plan = AgentPageWarmupPlan()
        _ = plan.start()
        _ = plan.settle()
        #expect(plan.start() == nil)
    }

    @MainActor @Test func newAgentPagesShowInWebKitUnlessChromiumTakesTheChat() {
        let hosting = FakeChromiumHosting()
        #expect(AgentPaneView.newPagesShowInWebKit(chromiumChat: true, hosting: nil),
                "no Chromium host")
        #expect(AgentPaneView.newPagesShowInWebKit(chromiumChat: false, hosting: hosting),
                "the agent chat stays on WebKit unless Chromium may take it")
        #expect(!AgentPaneView.newPagesShowInWebKit(chromiumChat: true, hosting: hosting))
        hosting.isAvailable = false
        #expect(AgentPaneView.newPagesShowInWebKit(chromiumChat: true, hosting: hosting),
                "Chromium unavailable")
        hosting.isAvailable = true
        hosting.preference = .webkit
        #expect(AgentPaneView.newPagesShowInWebKit(chromiumChat: true, hosting: hosting),
                "the person chose WebKit")
    }
}
