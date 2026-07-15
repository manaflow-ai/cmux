import CmuxAgentChat
import CMUXMobileCore
import CmuxMobileShellModel

extension ChatSessionDescriptor {
    func paneChatCard(defaultTitle: String) -> PaneChatCardSnapshot? {
        guard kind == .agent, let terminalID else { return nil }
        let status: MobileWorkspaceAgentStatus = switch state {
        case .working: .running
        case .needsInput: .needsInput
        case .idle, .ended: .idle
        }
        let resolvedTitle = title.flatMap { $0.isEmpty ? nil : $0 } ?? defaultTitle
        return PaneChatCardSnapshot(
            id: id,
            terminalID: terminalID,
            title: resolvedTitle,
            agentStatus: status
        )
    }
}
