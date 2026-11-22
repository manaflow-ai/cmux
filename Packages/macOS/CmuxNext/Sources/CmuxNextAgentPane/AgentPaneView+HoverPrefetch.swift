import CmuxNextDesignTokens
import Foundation

extension AgentPaneView {
    /// The page that reads a sidebar hover ahead: the agent chat on screen (`shown`), which hands the
    /// chat's tail to the host (``AgentPaneTailCache``) that the click's page draws first; with no agent
    /// chat on screen (a terminal, a browser page), the parked New Tab `spare`: it is connected to this
    /// Mac's acpmux and it is the page that click adopts (``AgentPaneSpareAdoption``), so the switch draws
    /// the chat from the spare's own read-ahead tier. Before, nothing read a hover from such a screen.
    public static func hoverReader(shown: AgentPaneView?, spare: AgentPaneView?) -> AgentPaneView? {
        shown ?? spare
    }

    /// The sidebar's pointer is on chat `session`'s row (nil: on no chat's row, or on one whose tab
    /// already has a page), forwarded to this page, the agent chat on screen, as its `chat.prefetch`
    /// with `hover` (HQ#5914, finding 2). Only the forward: whether the hover rests long enough to
    /// read, what it reads and keeps and when it is cancelled are the page's
    /// (webviews/src/agent-session/acpmux/hoverPrefetch.ts), which reads nothing in Low Power Mode;
    /// Low Power Mode turning on mid-dwell cancels the wait (``hoverPowerWatch``). A page of another
    /// machine's chat forwards nothing: its acpmux is not this Mac's. Not a gesture.
    public func forwardHover(_ session: String?) {
        guard !model.remoteChat else { return }
        let power = LowPowerMode.system
        if hoverPowerWatch == nil {
            hoverPowerWatch = power.observe { [weak self] enabled in if enabled { self?.sendHover(nil, lowPower: true) } }
        }
        sendHover(session, lowPower: power.isEnabled)
    }

    private func sendHover(_ session: String?, lowPower: Bool) {
        var params: [String: Any] = ["hover": true, "lowPower": lowPower]
        if let session { params["sessionId"] = session }
        guard let data = try? JSONSerialization.data(withJSONObject: params) else { return }
        evaluateScript("window.cmuxAcpmuxActions?.['chat.prefetch']?.(\(String(decoding: data, as: UTF8.self)));")
    }
}
