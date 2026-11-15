import CmuxNextAgentPane
import CmuxNextDaemon
import CmuxNextDaemonService
import CmuxNextWindowRules

/// Toggle Terminal and Chat's approval (``TerminalChatApproving``): while a pair's terminal drives the
/// session, the harness's dialog shows in its chat and is answered there. One per chat tab, the newest swap's,
/// owned by the chat's model, so it ends with the chat.
@MainActor enum TerminalChatApprovals {
    static func follow(terminal: TabModel, chat: String, services: AppServices) {
        guard let view = services.agentTabs.existingView(chat) else { return }
        (view.model.terminalApprovalWatch as? Watch)?.approving.stop()
        let daemon = services.machines.daemon(forTab: terminal)
        let face = TerminalApprovalFace(tab: terminal, connection: { [weak daemon] in daemon?.connection })
        let watch = Watch(face: face, approving: TerminalChatApproving(terminal: face, chat: view))
        view.model.terminalApprovalWatch = watch
        watch.approving.start()
    }

    /// The approving holds its faces weakly: the watch keeps the terminal face alive.
    @MainActor private final class Watch {
        let face: TerminalApprovalFace, approving: TerminalChatApproving
        init(face: TerminalApprovalFace, approving: TerminalChatApproving) { (self.face, self.approving) = (face, approving) }
    }
}

extension AgentPaneView: TerminalApprovalChat {
    public func showTerminalApproval(_ approval: WindowRules.TerminalApproval?,
                                     answer: @escaping @MainActor (Int, String, String) async -> Bool) {
        model.onTerminalApproval = { await answer($0.key, $0.label, $0.question) }
        AgentPaneTerminalApproval.show(approval.map { shown in
            AgentPaneTerminalApproval(question: shown.question, header: shown.header, command: shown.command, detail: shown.detail,
                                      options: shown.options.map { .init(key: $0.key, label: $0.label, kind: $0.kind) })
        }, on: self)
    }
}
