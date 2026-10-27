import CmuxNextAgentPane
import CmuxNextCompat
import CmuxNextInput
import CmuxNextPages
import CmuxNextWakeups

extension WebUIHost {
    /// A page host for an agent tab store test: no Chromium host (every page is WebKit), no open
    /// panel, its own registry.
    static func agentTabsTestHost() -> WebUIHost {
        WebUIHost(chromium: nil, openPanel: nil, memory: ManualMemoryLevelRegistry())
    }
}

extension AgentPaneGestureRouter {
    /// A gesture router over a fresh input tap, for a test that never dispatches through one.
    static func testing() -> AgentPaneGestureRouter { AgentPaneGestureRouter(input: InputEventTap()) }
}

extension MainDeadlineScheduler {
    /// A deadline scheduler on a fresh main-thread scheduler, for a pane test's dictation.
    static func agentPaneTesting() -> MainDeadlineScheduler { MainDeadlineScheduler(work: MainWorkScheduler(budget: MainFrameBudget())) }
}
