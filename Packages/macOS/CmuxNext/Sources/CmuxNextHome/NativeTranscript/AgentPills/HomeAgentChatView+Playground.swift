#if DEBUG
import AppKit

/// DEBUG ONLY: the Agent Messages Playground's made-up agents in the shipped chat view.
extension HomeAgentChatView {
    /// The chat of playground agent `agent`.
    convenience init(agent: HomeAgentPlaygroundAgent, compact: Bool = false, actions: Actions) {
        self.init(content: agent.content, compact: compact, actions: actions)
    }
}

extension HomeAgentPlaygroundAgent {
    /// What its chat shows: its steps behind "Worked for ›", its senders as the shipped labels.
    var content: HomeAgentChatContent {
        HomeAgentChatContent(
            peer: peer, title: title, status: status, task: task, workedFor: workedFor, details: steps,
            messages: messages.map { message in
                let sender: HomeAgentChatContent.Sender = switch message.sender {
                case nil: .agent
                case "Chief": .chief
                default: .you
                }
                return HomeAgentChatContent.Message(sender: sender, text: message.text)
            },
            workspaceLink: nil)
    }
}
#endif
