import CmuxNextAgentPane
import CmuxNextDaemon
import CmuxNextDaemonService
import CmuxNextWindowRules

/// Toggle Terminal and Chat's approval (``TerminalChatApproving``): while a pair's terminal drives the
/// session, the harness's dialog shows in its chat and is answered there. One per chat tab, the newest swap's.
@MainActor enum TerminalChatApprovals {
    private static var pairs: [String: (face: TerminalApprovalFace, approving: TerminalChatApproving)] = [:]

    static func follow(terminal: TabModel, chat: String, services: AppServices) {
        pairs[chat]?.approving.stop()
        guard let view = services.agentTabs.existingView(chat) else { return pairs[chat] = nil }
        let face = TerminalApprovalFace(tab: terminal, daemon: services.machines.daemon(forTab: terminal))
        let approving = TerminalChatApproving(terminal: face, chat: view)
        pairs[chat] = (face, approving)
        approving.start()
    }
}

/// A pair's terminal as its approval reads it: the daemon's agent state, screen and keys (the face may be hidden).
@MainActor final class TerminalApprovalFace: TerminalApprovalTerminal {
    private weak var tab: TabModel?
    private let daemon: DaemonService

    init(tab: TabModel, daemon: DaemonService) {
        self.tab = tab
        self.daemon = daemon
    }

    var approvalBlocked: Bool { tab?.agent?.state == .blocked }

    func approvalScreen() async -> String? {
        guard let tab, let connection = daemon.connection else { return nil }
        return try? await connection.request(ReadScreenRequest(surface: tab.surface), timeout: .seconds(2)).text
    }

    func approvalPress(_ keys: [String]) async -> Bool {
        guard let tab, let connection = daemon.connection else { return false }
        return (try? await connection.sendKeys(tab.surface, keys)) != nil
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
