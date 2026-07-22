import CmuxAgentChat

enum WorkspaceTitleMenuLabelToken: Equatable {
    case chat(
        descriptor: ChatSessionDescriptor,
        agentState: ChatAgentState,
        isConnected: Bool,
        titleOverride: String?,
        subtitle: String?
    )
    case browser(title: String)
    case standard(title: String, subtitle: String?)
}
