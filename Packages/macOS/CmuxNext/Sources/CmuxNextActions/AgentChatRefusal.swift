public import Foundation

/// Why an agent-chat action can't run, in its own words: the action's title and the cause.
public nonisolated enum AgentChatRefusal: Sendable {
    /// No agent chat shows where it runs.
    case noChat
    /// The chat's session has not started.
    case notStarted
    /// The chat has no project folder (an agent-home chat's folder never leaves the chat).
    case noFolder
    /// The chat runs on another machine.
    case remote
    /// Automation ran it without asking for focus.
    case needsFocus
    /// It ran without the value it sets.
    case needsValue

    /// The bundle with the refusals' string table.
    public static var bundle: Bundle { .module }

    /// The reason, naming the action `title`.
    public func reason(_ title: String) -> String {
        let format = switch self {
        case .noChat: String(localized: "refusal.agentChat.noChat", defaultValue: "%@ works in agent chats. Focus one first.", table: "AgentChatMenu", bundle: .module)
        case .notStarted: String(localized: "refusal.agentChat.notStarted", defaultValue: "%@ works once the chat has started.", table: "AgentChatMenu", bundle: .module)
        case .noFolder: String(localized: "refusal.agentChat.noFolder", defaultValue: "%@ works in chats with a project folder.", table: "AgentChatMenu", bundle: .module)
        case .remote: String(localized: "refusal.agentChat.remote", defaultValue: "%@ works only in chats on this Mac.", table: "AgentChatMenu", bundle: .module)
        case .needsFocus: String(localized: "refusal.agentChat.needsFocus", defaultValue: "%@ requires focus.", table: "AgentChatMenu", bundle: .module)
        case .needsValue: String(localized: "refusal.agentChat.needsValue", defaultValue: "%@ needs a value.", table: "AgentChatMenu", bundle: .module)
        }
        return String(format: format, title)
    }
}

public extension ActionRegistry {
    /// `cause`'s reason for the action `id`, named by its title.
    func reason(_ cause: AgentChatRefusal, for id: ActionID) -> String {
        cause.reason(descriptor(for: id)?.title ?? id.rawValue)
    }

    /// Refuses the action `id` with `cause`'s reason. Returns nil, for `guard ... else { return refuse(...) }`.
    @discardableResult func refuse<T>(_ cause: AgentChatRefusal, _ id: ActionID) -> T? {
        refuse(reason(cause, for: id))
        return nil
    }

    /// Statement form of ``refuse(_:_:)-generic``.
    func refuse(_ cause: AgentChatRefusal, _ id: ActionID) {
        refuse(reason(cause, for: id))
    }
}
