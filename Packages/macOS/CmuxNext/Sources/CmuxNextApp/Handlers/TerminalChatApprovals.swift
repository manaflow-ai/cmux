import CmuxNextAgentPane
import CmuxNextDaemon
import CmuxNextDaemonService
import CmuxNextWindowRules

/// Toggle Terminal and Chat's approval (``TerminalChatApproving``): while a pair's terminal drives the session, the
/// harness's dialog shows in its chat and is answered there. One per chat tab, the newest swap's, kept by the chat's model.
@MainActor enum TerminalChatApprovals {
    static func follow(terminal: TabModel, chat: String, services: AppServices) {
        guard let view = services.agentTabs.existingView(chat) else { return }
        (view.model.terminalApprovalWatch as? Card)?.approving.stop()
        let daemon = services.machines.daemon(forTab: terminal)
        let card = Card(view: view, face: TerminalApprovalFace(tab: terminal, connection: { [weak daemon] in daemon?.connection }))
        view.model.terminalApprovalWatch = card
        card.approving.start()
    }

    /// The chat face: the dialog as the chat's card (``AgentPaneTerminalApproval``), a click as `answer`. The chat's model
    /// keeps it, and it keeps the terminal face and the approving, which holds both faces weakly.
    @MainActor private final class Card: TerminalApprovalChat {
        private weak var view: AgentPaneView?
        private let face: TerminalApprovalFace
        private(set) lazy var approving = TerminalChatApproving(terminal: face, chat: self)
        init(view: AgentPaneView, face: TerminalApprovalFace) { (self.view, self.face) = (view, face) }

        func showTerminalApproval(_ approval: WindowRules.TerminalApproval?,
                                  answer: @escaping @MainActor (Int, String, String) async -> Bool) {
            guard let view else { return }
            view.model.onTerminalApproval = { await answer($0.key, $0.label, $0.id) }
            AgentPaneTerminalApproval.show(approval.map { shown in
                AgentPaneTerminalApproval(id: shown.id, question: shown.question, header: shown.header, command: shown.command,
                                          detail: shown.detail, options: shown.options.map { .init(key: $0.key, label: $0.label, kind: $0.kind) })
            }, on: view)
        }
    }
}
