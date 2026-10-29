import CmuxNextPages
import CmuxNextPagesTestSupport
import Testing
@testable import CmuxNextAgentPane

/// The agent pages' WebKit warm-up: when its page may be made and when it goes,
/// which engine a new agent page opens in, decided with no side effect, and no warm-up page while agent
/// pages open in Chromium.
@Suite struct AgentPageWarmupPlanTests {
    @Test func aWarmupQueuedPastTheSettleStillMakesItsPage() {
        var plan = AgentPageWarmupPlan()
        let settleDropped = plan.settle()
        #expect(!settleDropped, "no page yet: nothing goes")
        #expect(plan.start(agentPagesShowInWebKit: true) == .make(dropsOnLoad: true),
                "the afterStartup warm-up still starts; its page goes once its load ends")
        #expect(plan.pageAlive)
        let loadDropped = plan.loadEnded()
        #expect(loadDropped, "the empty page goes, WebKit's setup and the pool stay")
        #expect(!plan.pageAlive)
    }

    @Test func aWarmupBeforeTheSettleKeepsItsPageUntilTheSettle() {
        var plan = AgentPageWarmupPlan()
        #expect(plan.start(agentPagesShowInWebKit: true) == .make(dropsOnLoad: false), "made before the settle: kept for the first agent page")
        let loadDropped = plan.loadEnded()
        #expect(!loadDropped, "its load ending does not drop it before the settle")
        let settleDropped = plan.settle()
        #expect(settleDropped)
        #expect(!plan.pageAlive)
    }

    @Test func anAgentPageMadeFirstMeansNoWarmup() {
        var plan = AgentPageWarmupPlan()
        plan.agentPageMade()
        #expect(plan.start(agentPagesShowInWebKit: true) == .skip(.agentPageStartedWebKit), "that page started WebKit")
        #expect(!plan.pageAlive)
    }

    @Test func anAgentPageMadeFirstIsTheReasonEvenWhenChromiumIsTheDefaultNow() {
        var plan = AgentPageWarmupPlan()
        plan.agentPageMade()
        #expect(plan.start(agentPagesShowInWebKit: false) == .skip(.agentPageStartedWebKit),
                "a restored WebKit agent page started WebKit: the bench must not read this launch as WebKit-free")
    }

    @Test func anAgentPageLoadedDropsTheWarmupPage() {
        var plan = AgentPageWarmupPlan()
        _ = plan.start(agentPagesShowInWebKit: true)
        let loadedDropped = plan.agentPageLoaded()
        #expect(loadedDropped)
        let settleDropped = plan.settle()
        #expect(!settleDropped, "already gone")
    }

    @Test func theWarmupStartsOncePerRun() {
        var plan = AgentPageWarmupPlan()
        _ = plan.start(agentPagesShowInWebKit: true)
        _ = plan.settle()
        #expect(plan.start(agentPagesShowInWebKit: true) == .skip(.alreadyRan))
    }

    @Test func noWarmupWhileAgentPagesOpenInChromium() {
        var plan = AgentPageWarmupPlan()
        #expect(plan.start(agentPagesShowInWebKit: false) == .skip(.agentPagesInChromium),
                "a WebKit page warms nothing a Chromium agent page uses")
        #expect(!plan.started)
        #expect(!plan.pageAlive)
        let settleDropped = plan.settle()
        #expect(!settleDropped, "no page was made")
    }

    @MainActor @Test func chromiumDefaultMakesNoWebKitWarmupPage() {
        let hosting = FakeChromiumHosting()
        let warmup = AgentPageWarmup(chromiumChat: { true })
        #expect(warmup.start(webUI: .agentPaneTestHost(chromium: hosting)) == .agentPagesInChromium,
                "Chromium is the default and takes the agent chat: no WKWebView at launch")
    }

    @MainActor @Test func aWebKitAgentChatStillWarms() {
        let hosting = FakeChromiumHosting()
        hosting.preference = .webkit
        let warmup = AgentPageWarmup(chromiumChat: { true })
        #expect(warmup.start(webUI: .agentPaneTestHost(chromium: hosting)) == .made, "the person chose WebKit")
        warmup.settle()
    }

    @MainActor @Test func chromiumChatOffStillWarms() {
        let warmup = AgentPageWarmup(chromiumChat: { false })
        #expect(warmup.start(webUI: .agentPaneTestHost(chromium: FakeChromiumHosting())) == .made,
                "the agent chat stays on WebKit")
        warmup.settle()
    }

    @MainActor @Test func eachStartReadsTheEngineDecisionAgain() {
        let hosting = FakeChromiumHosting()
        let webUI = WebUIHost.agentPaneTestHost(chromium: hosting)
        let warmup = AgentPageWarmup(chromiumChat: { true })
        #expect(warmup.start(webUI: webUI) == .agentPagesInChromium, "agent pages open in Chromium: no WebKit page")
        hosting.preference = .webkit
        #expect(warmup.start(webUI: webUI) == .made, "the person chose WebKit since: a later start makes the page")
        #expect(warmup.start(webUI: webUI) == .alreadyRan)
        warmup.settle()
    }

    @Test func eachOutcomeLeavesItsOwnLaunchMark() {
        #expect(AgentPageWarmupOutcome.made.launchMark == "launch.agent_page_warmup")
        #expect(AgentPageWarmupOutcome.agentPageStartedWebKit.launchMark == "launch.agent_page_warmup_not_needed")
        #expect(AgentPageWarmupOutcome.agentPagesInChromium.launchMark == "launch.agent_page_warmup_chromium")
        #expect(AgentPageWarmupOutcome.alreadyRan.launchMark == nil, "the first start marked this launch")
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
