#if os(iOS)
import CmuxAgentChat
import Foundation

/// A flattened, render-ready item in the cross-agent Feed.
///
/// Agent messages and terminal command blocks intentionally share one value
/// type. That gives every visual variant the same complete primitive coverage
/// and keeps actions routed through one store instead of style-specific logic.
struct AgentFeedEntry: Identifiable, Equatable, Sendable {
    enum Content: Equatable, Sendable {
        case message(ChatMessage)
        case terminalBlock(TerminalCommandBlock)
        case presence(ChatAgentState)
    }

    let id: String
    let sessionID: String
    let workspaceID: String?
    let workspaceName: String
    let terminalID: String?
    let agentName: String
    let sessionTitle: String?
    let timestamp: Date
    let state: ChatAgentState
    let content: Content
    let requiresReply: Bool
    let isStreaming: Bool

    var message: ChatMessage? {
        guard case .message(let message) = content else { return nil }
        return message
    }

    var terminalBlock: TerminalCommandBlock? {
        guard case .terminalBlock(let block) = content else { return nil }
        return block
    }

    var isPresence: Bool {
        if case .presence = content { return true }
        return false
    }
}
#endif
