import Foundation

enum AgentConversationForkExecutableBindingStorage: Equatable, Hashable, Sendable {
    case adjacentCopy(AgentConversationForkExecutableBindingAdjacentCopy)
    case protectedSource(expectedShellStatSignature: String)
}
