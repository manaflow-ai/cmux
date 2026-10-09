import AppKit
import CmuxNextActions

/// App actions on an agent chat's own tab: the header's tools and "..." menu
/// (acpmux header/ChatHeaderTools.tsx) and the empty-space right-click menu (`agentChat`
/// placements). Kept off `AgentTabStore`, whose wiring is at its type budget.
@MainActor
struct AgentChatTabActions {
    /// The chat's tab now (a provisional id becomes the store's).
    let tab: @MainActor () -> String
    let registry: @MainActor () -> ActionRegistry?

    /// A header action, with the folder it names when it names one.
    func run(_ id: String, cwd: String?) {
        let arguments: [String: ActionValue] = cwd.map { ["cwd": .string($0)] } ?? [:]
        let invocation = ActionInvocation(target: ActionTargetRef(kind: .tab, id: tab()), arguments: arguments, origin: .user)
        _ = registry()?.perform(ActionID(rawValue: id), invocation: invocation)
    }

    /// The empty-space menu's items, detached for the pane's menu to take.
    func menuItems() -> [NSMenuItem] {
        guard let registry = registry() else { return [] }
        let menu = registry.makeContextMenu(for: .agentChat, target: ActionTargetRef(kind: .tab, id: tab()))
        let items = menu.items
        menu.removeAllItems()
        return items
    }
}
