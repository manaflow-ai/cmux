import CmuxNextAgentPane
import Foundation

/// The agent pane's reply in place to another agent's message (``AgentPaneAgentReply``): the
/// relay hands acpmux's signed reply to the daemon of the tab's machine, which mints a launch
/// credential for the replying chat on the app's own connection and sends it as that chat. The
/// relay never calls it for a chat on another machine.
extension AgentTabStore {
    func wireAgentReply(_ model: AgentPaneModel, key provisional: String) {
        model.transport.sendAgentReply = { [weak self] reply in
            guard let self, let daemon = daemonForTab(resolve(provisional)) else { throw AgentPaneAgentReply.Failure.unavailable }
            return try await daemon.sendAgentReply(reply)
        }
    }
}
