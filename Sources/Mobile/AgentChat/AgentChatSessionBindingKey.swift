import Foundation

/// Stable lookup key for chat sessions bound to one mobile-visible terminal.
struct AgentChatSessionBindingKey: Hashable, Sendable {
    var workspaceID: String
    var surfaceID: String
}
