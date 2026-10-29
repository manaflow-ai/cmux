import CmuxNextAgentPane
import CmuxNextCompat
import CmuxNextInput
import CmuxNextPages
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport

extension WebUIHost {
    /// A page host for an agent tab store test: no Chromium host (every page is WebKit), no open
    /// panel, its own registry.
    static func agentTabsTestHost() -> WebUIHost {
        WebUIHost(chromium: nil, openPanel: nil, memory: ManualMemoryLevelRegistry(), deadlines: .testing())
    }
}

extension AgentPaneGestureRouter {
    /// A gesture router over a fresh input tap, for a test that never dispatches through one.
    static func testing() -> AgentPaneGestureRouter { AgentPaneGestureRouter(input: InputEventTap()) }
}
