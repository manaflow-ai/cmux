import CmuxNextAgentPane
import CmuxNextCompat
import CmuxNextInput
import CmuxNextPages
import CmuxNextPagesTestSupport
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport

extension WebUIHost {
    /// A page host for an agent pane test: `chromium` makes its Chromium pages (nil keeps every page
    /// on WebKit), with no open panel and its own registry.
    static func agentPaneTestHost(chromium: (any PageChromiumHosting)? = nil) -> WebUIHost {
        WebUIHost(chromium: chromium, openPanel: nil,
                  memory: QuietMemoryRegistry(), deadlines: .testing())
    }
}

extension AgentPaneGestureRouter {
    /// A gesture router over a fresh input tap, for a test that never dispatches through one.
    static func testing() -> AgentPaneGestureRouter { AgentPaneGestureRouter(input: InputEventTap()) }
}
