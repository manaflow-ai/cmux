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
    public static var bundle: Bundle { .localizedModule }

    /// The reason, naming the action `title`.
    public func reason(_ title: String) -> String {
        let format = switch self {
        case .noChat: String(localized: "refusal.agentChat.noChat", defaultValue: "%@ works in agent chats. Focus one first.", table: "AgentChatMenu", bundle: .localizedModule)
        case .notStarted: String(localized: "refusal.agentChat.notStarted", defaultValue: "%@ works once the chat has started.", table: "AgentChatMenu", bundle: .localizedModule)
        case .noFolder: String(localized: "refusal.agentChat.noFolder", defaultValue: "%@ works in chats with a project folder.", table: "AgentChatMenu", bundle: .localizedModule)
        case .remote: String(localized: "refusal.agentChat.remote", defaultValue: "%@ works only in chats on this Mac.", table: "AgentChatMenu", bundle: .localizedModule)
        case .needsFocus: String(localized: "refusal.agentChat.needsFocus", defaultValue: "%@ requires focus.", table: "AgentChatMenu", bundle: .localizedModule)
        case .needsValue: String(localized: "refusal.agentChat.needsValue", defaultValue: "%@ needs a value.", table: "AgentChatMenu", bundle: .localizedModule)
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
    /// Quiet: a caller (palette, CLI, MCP) gets the reason; a shortcut or menu run on something that
    /// is not a chat it serves does nothing, never a toast that says to go focus one (Leo
    /// 2026-11-17: "just... stop showijg the toggle on gui").
    @discardableResult func refuse<T>(_ cause: AgentChatRefusal, _ id: ActionID) -> T? {
        refuse(reason(cause, for: id), quiet: true)
        return nil
    }

    /// Statement form of ``refuse(_:_:)-generic``.
    func refuse(_ cause: AgentChatRefusal, _ id: ActionID) {
        refuse(reason(cause, for: id), quiet: true)
    }

    /// Offers the bound action `id` (call after its bind) only where it runs: wherever `lookup`, the
    /// handler's own lookup of what it acts on, refuses, the action's palette and menu rows are
    /// disabled with that reason, its context-menu row is left out, a keyboard or menu run does
    /// nothing, and a CLI or MCP run gets the reason back (``ActionTargetVisibility/gate(_:in:reason:)``).
    /// One lookup decides both, so a row's state and its run agree. An explicit target that names
    /// nothing is left to the handler (`not_found` on the socket).
    @MainActor func gate(_ id: ActionID, onRefusalOf lookup: @escaping @MainActor (ActionInvocation) -> Void) {
        ActionTargetVisibility.gate(id, in: self) { [weak self] invocation in
            guard let refused = self?.capturingTypedRefusal({ lookup(invocation) }), !refused.isNotFound else { return nil }
            return refused.reason
        }
    }
}
