import AppKit
import CmuxNextActions

/// App actions on an agent chat's own tab: the header's tools and "..." menu
/// (acpmux header/ChatHeaderTools.tsx), the empty-space right-click menu (`agentChat`
/// placements) and Search the Web on selected text. Kept off `AgentTabStore`, whose wiring is
/// at its type budget.
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

    /// Closes tab `id` (a quick action's split, AgentChatSplitToggles) as its own Close Tab does.
    func close(tab id: String) {
        _ = registry()?.perform("closeTab", invocation: ActionInvocation(target: ActionTargetRef(kind: .tab, id: id), origin: .user))
    }

    /// Search the Web on selected chat text: a browser tab beside the chat, with the omnibar's
    /// search engine.
    func searchWeb(_ text: String) {
        let invocation = ActionInvocation(target: ActionTargetRef(kind: .tab, id: tab()), arguments: ["text": .string(text)], origin: .user)
        _ = registry()?.perform("browser.selection.search", invocation: invocation)
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
